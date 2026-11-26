using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：Apple 后端平台实现内部引用本平台 Native 声明（#189）
using Ryujinx.Audio.Backends.CompatLayer;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Audio.Backends.Apple   // 平台例外：Apple 后端平台实现的命名空间（#189 显式下混档）
{
    // S2Arm (#189): the explicit 5.1 (6-channel PCM16) -> stereo downmix for the Apple backend.
    //
    // Why: since the real-channel-count fix the backend reports stereo on <6-channel devices, and the renderer folds
    // the 5.1 mix itself: with the game's DownMixParameter when the game provides one, otherwise with
    // Constants.DefaultSurroundToStereoCoefficients = [1.0, 0.707, 0.251, 0.707] (CommandGenerator's fallback),
    // which is unnormalized — L = FL + 0.707*C + 0.251*LFE + 0.707*BL. Measured at 48 kHz with a 997 Hz sine:
    // FL+FC both at 0.9 folds to 1.536 (2632/4800 samples clipped), all six at 0.9 folds to 2.399 (3484/4800 clipped),
    // saturating to PCM16. The system's explicit downmix (AudioConverter, kAudioConverterPropertyPerformDownmix)
    // is normalized: front 0.4142, centre/surround 0.2929, LFE dropped — worst case (front + centre + one surround,
    // 0.4142 + 2*0.2929) sums to 1.0 and does not clip (measured: all six at 0.9 folds to exactly 0.9).
    //
    // Modes; the default is native and keeps the current path:
    //   sys     - S2A_AUDIO_OUT=sys: AudioConverter with kAudioConverterPropertyPerformDownmix + channel layouts
    //             (MPEG_5_1_A in, stereo out): the system's explicit downmix, normalized, no clipping.
    //   matrix  - S2A_AUDIO_OUT=matrix: host Q15 downmix with the same coefficients as
    //             Downmixing.DownMixSurroundToStereo (i.e. the same fold the renderer does without game
    //             coefficients). This is the fallback when the converter or the spatial mixer cannot be built or a
    //             slice fails; it can also be selected explicitly for A/B against the compat layer.
    //   native  - S2A_AUDIO_OUT=native: keep the current behaviour (default; identical to not setting the variable).
    //   spatial - NOT selected through S2A_AUDIO_OUT: the product path is the user's device type + the matching
    //             virtual-surround switch (S2A_AUDIO_DEVICE=builtin + S2A_AUDIO_VS_SPEAKERS, headphones +
    //             S2A_AUDIO_VS_HEADPHONES) — the session maps that to SpatialSpeakers / SpatialHeadphones. AUSM
    //             ('3dem') with an explicit SpatialMixerOutputType (BuiltInSpeakers / Headphones; .auto degrades to
    //             ExternalSpeakers plain panning on 5.1 paths, see docs/坑记录.md), AmbienceBed, UseOutputType.
    internal enum AppleOutputMode
    {
        Native = 0,
        Matrix = 1,
        System = 2,
        SpatialSpeakers = 3,
        SpatialHeadphones = 4,
    }

    internal static class AppleOutputModeSelector
    {
        private const AppleOutputMode DefaultMode = AppleOutputMode.Native;

        public static AppleOutputMode FromEnvironment()
        {
            string value = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");

            if (string.IsNullOrWhiteSpace(value))
            {
                return DefaultMode;
            }

            switch (value.Trim().ToLowerInvariant())
            {
                case "matrix":
                case "q15":
                    return AppleOutputMode.Matrix;
                case "sys":
                case "system":
                case "converter":
                    return AppleOutputMode.System;
                case "native":
                case "off":
                    return AppleOutputMode.Native;
                default:
                    Console.Error.WriteLine($"[声] 【红】S2A_AUDIO_OUT=「{value}」不认识（可用 sys / matrix / native）：按 {ModeName(DefaultMode)}");
                    return DefaultMode;
            }
        }

        public static string ModeName(AppleOutputMode mode)
        {
            return mode switch
            {
                AppleOutputMode.Matrix => "矩阵（Q15，系数同渲染器回落）",
                AppleOutputMode.System => "系统显式下混（AudioConverter，归一化不削波）",
                AppleOutputMode.SpatialSpeakers => "内置扬声器虚拟环绕（AUSM，显式 BuiltInSpeakers）",
                AppleOutputMode.SpatialHeadphones => "耳机虚拟环绕（AUSM，显式 Headphones，双耳渲染）",
                _ => "native（缺省：不上报 5.1，渲染器自己下混）",
            };
        }
    }

    // One instance per folded 6-channel output session. Process() is called from the device pump (guest buffers) and
    // from the renderer thread (Data buffers), so it serialises internally. Input is interleaved PCM16 6-channel
    // (FL FR FC LFE BL BR, the renderer's channel order), output is interleaved PCM16 stereo; the frame count is
    // preserved, so the session's byte accounting and release cadence stay unchanged.
    internal sealed unsafe class AppleOutputProcessor : IDisposable
    {
        private const int InputChannels = 6;
        private const int OutputChannels = 2;
        private const int InputBytesPerFrame = InputChannels * sizeof(short);
        private const int OutputBytesPerFrame = OutputChannels * sizeof(short);

        private readonly object _lock = new();
        private readonly AppleOutputMode _requestedMode;
        private readonly int _sampleRate;
        private readonly int _maxFrames;
        private AppleOutputMode _mode;
        private int _failures;
        private bool _disposed;

        // AudioConverter ('sys')
        private nint _converter;
        private nint _convInputProcPtr;
        private nint _convOutputAbl;
        private AudioConverterInterop.AudioConverterComplexInputDataProc _convInputProc;
        private int _convFrames;
        private nint _convInput;
        private int _convDone;

        // AUSM '3dem'（SpatialSpeakers / SpatialHeadphones）：手动拉取的器件实例、输入平面、输出平面与 AudioBufferList
        private nint _unit;
        private nint _spatialOutAbl;
        private readonly float[][] _spatialInPlanes = new float[InputChannels][];
        private float*[] _spatialOutPlanes;
        private AudioUnitInterop.AURenderCallback _spatialInputProc;
        private int _spatialFrames;
        private double _spatialSampleTime;
        private AudioUnitInterop.AudioTimeStamp _spatialTimeStamp;
        // 最近一次 AUSM 渲染失败的 rc 与片长（CountFailure 的第一次【红】日志带出，评审 11-16：失败不能只进计数）
        private int _spatialRenderRc;
        private int _spatialRenderFrames;
        // 截幅采样累计（AUSM 输出没有幅度上限保证，按 PCM16 截幅；评审 11-16：进收局统计，判断「VS 开了声音发破」）
        private long _clippedSamples;

        private GCHandle _self;

        public string InitError { get; private set; }
        public AppleOutputMode EffectiveMode => _mode;
        // 收局统计（评审 11-16）：渲染失败片数（只在本类内写）与截幅采样累计
        internal int FailureCount => _failures;
        internal long ClippedSampleCount => Interlocked.Read(ref _clippedSamples);

        private AppleOutputProcessor(AppleOutputMode mode, int sampleRate, int maxFrames)
        {
            _requestedMode = mode;
            _sampleRate = sampleRate;
            _maxFrames = Math.Max(16, maxFrames);
            _mode = mode;
        }

        // Never returns null and never leaves a mode that cannot produce audio: a converter or spatial mixer that
        // cannot be built falls back to matrix (InitError says why; the caller logs it once).
        public static AppleOutputProcessor Create(AppleOutputMode mode, int sampleRate, int maxFrames)
        {
            AppleOutputProcessor processor = new(mode, sampleRate, maxFrames);

            if (mode == AppleOutputMode.System && !processor.InitSystem())
            {
                processor._mode = AppleOutputMode.Matrix;
            }

            if ((mode == AppleOutputMode.SpatialSpeakers || mode == AppleOutputMode.SpatialHeadphones)
                && !processor.InitSpatial(mode == AppleOutputMode.SpatialSpeakers
                    ? AudioUnitInterop.kSpatialMixerOutputType_BuiltInSpeakers
                    : AudioUnitInterop.kSpatialMixerOutputType_Headphones))
            {
                processor._mode = AppleOutputMode.Matrix;
            }

            return processor;
        }

        private static AudioToolbox.AudioStreamBasicDescription MakeFormat(int rate, int channels)
        {
            return new AudioToolbox.AudioStreamBasicDescription
            {
                SampleRate = rate,
                FormatID = AudioToolbox.kAudioFormatLinearPCM,
                FormatFlags = AudioToolbox.kAudioFormatFlagIsSignedInteger | AudioToolbox.kAudioFormatFlagIsPacked,
                BytesPerPacket = (uint)(channels * sizeof(short)),
                FramesPerPacket = 1,
                BytesPerFrame = (uint)(channels * sizeof(short)),
                ChannelsPerFrame = (uint)channels,
                BitsPerChannel = 16,
                Reserved = 0,
            };
        }

        private static AudioToolbox.AudioChannelLayout Layout(uint tag)
        {
            return new AudioToolbox.AudioChannelLayout
            {
                AudioChannelLayoutTag = tag,
                AudioChannelBitmap = 0,
                NumberChannelDescriptions = 0,
            };
        }

        private bool InitSystem()
        {
            AudioToolbox.AudioStreamBasicDescription input = MakeFormat(_sampleRate, InputChannels);
            AudioToolbox.AudioStreamBasicDescription output = MakeFormat(_sampleRate, OutputChannels);

            int rc = AudioConverterInterop.AudioConverterNew(ref input, ref output, out _converter);

            if (rc != 0 || _converter == 0)
            {
                InitError = $"AudioConverterNew rc={rc}";

                return false;
            }

            AudioToolbox.AudioChannelLayout inputLayout = Layout(AudioToolbox.kAudioChannelLayoutTag_MPEG_5_1_A);
            AudioToolbox.AudioChannelLayout outputLayout = Layout(AudioConverterInterop.kAudioChannelLayoutTag_Stereo);

            rc = AudioConverterInterop.AudioConverterSetProperty(_converter, AudioConverterInterop.PropertyInputChannelLayout,
                (uint)sizeof(AudioToolbox.AudioChannelLayout), &inputLayout);

            if (rc == 0)
            {
                rc = AudioConverterInterop.AudioConverterSetProperty(_converter, AudioConverterInterop.PropertyOutputChannelLayout,
                    (uint)sizeof(AudioToolbox.AudioChannelLayout), &outputLayout);
            }

            uint downmix = 1;

            if (rc == 0)
            {
                rc = AudioConverterInterop.AudioConverterSetProperty(_converter, AudioConverterInterop.PropertyPerformDownmix,
                    sizeof(uint), &downmix);
            }

            if (rc != 0)
            {
                InitError = $"AudioConverter 布局 / PerformDownmix rc={rc}";
                AudioConverterInterop.AudioConverterDispose(_converter);
                _converter = 0;

                return false;
            }

            _self = GCHandle.Alloc(this);
            _convInputProc = ConverterInput;
            _convInputProcPtr = Marshal.GetFunctionPointerForDelegate(_convInputProc);
            _convOutputAbl = Marshal.AllocHGlobal(AudioConverterInterop.AudioBufferListBuffersOffset + sizeof(AudioConverterInterop.AudioBuffer));

            return true;
        }

        private static AudioToolbox.AudioStreamBasicDescription MakeSpatialFormat(int rate, int channels)
        {
            // AUSM 的输入 / 输出都用 float32 非交织平面（采样格式与 'sys' 的 PCM16 交织不同，布局声明才有效）
            return new AudioToolbox.AudioStreamBasicDescription
            {
                SampleRate = rate,
                FormatID = AudioToolbox.kAudioFormatLinearPCM,
                FormatFlags = AudioToolbox.kAudioFormatFlagIsFloat | AudioToolbox.kAudioFormatFlagIsNonInterleaved,
                BytesPerPacket = sizeof(float),
                FramesPerPacket = 1,
                BytesPerFrame = sizeof(float),
                ChannelsPerFrame = (uint)channels,
                BitsPerChannel = 32,
                Reserved = 0,
            };
        }

        // 空间化档的属性 / 步骤包装：失败写 InitError、收掉器件实例（Create 回落矩阵，调用方打一次【红】）
        private bool SpatialProp(string step, uint property, uint scope, uint element, void* data, uint size)
        {
            return SpatialStep(step, AudioUnitInterop.AudioUnitSetProperty(_unit, property, scope, element, data, size));
        }

        private bool SpatialStep(string step, int rc)
        {
            if (rc == 0)
            {
                return true;
            }

            InitError = $"AUSM {step} rc={rc}";
            AudioUnitInterop.AudioComponentInstanceDispose(_unit);
            _unit = nint.Zero;

            return false;
        }

        // S2Arm（#189 后续，5.1 虚拟环绕）：AUSpatialMixer（'3dem'）手动拉取——输入 6ch MPEG_5_1_A、输出 2ch Stereo
        //   （都 float32 非交织）、AmbienceBed、UseOutputType、显式 SpatialMixerOutputType（不用 .auto：5.1 路径上
        //   内置 / USB / DisplayPort 三路由实测全退化为 ExternalSpeakers 普通平移，见 docs/坑记录.md）。属性设置顺序
        //   照 5.1 AUGraph 探针（evidence/bed51_augraph.swift，本机实测过）；渲染时 mSampleTime 严格单调递增。
        private bool InitSpatial(uint outputType)
        {
            AudioUnitInterop.AudioComponentDescription description = new()
            {
                ComponentType = AudioUnitInterop.kAudioUnitType_Mixer,
                ComponentSubType = AudioUnitInterop.kAudioUnitSubType_SpatialMixer,
                ComponentManufacturer = AudioUnitInterop.kAudioUnitManufacturer_Apple,
                ComponentFlags = 0,
                ComponentFlagsMask = 0,
            };

            nint component = AudioUnitInterop.AudioComponentFindNext(nint.Zero, ref description);

            if (component == nint.Zero)
            {
                InitError = "AUSM 找不到 AUSpatialMixer（'3dem'）器件";
                return false;
            }

            if (!SpatialStep("AudioComponentInstanceNew", AudioUnitInterop.AudioComponentInstanceNew(component, out _unit)))
            {
                return false;
            }

            AudioToolbox.AudioStreamBasicDescription input = MakeSpatialFormat(_sampleRate, InputChannels);
            AudioToolbox.AudioStreamBasicDescription output = MakeSpatialFormat(_sampleRate, OutputChannels);
            AudioToolbox.AudioChannelLayout inputLayout = Layout(AudioToolbox.kAudioChannelLayoutTag_MPEG_5_1_A);
            AudioToolbox.AudioChannelLayout outputLayout = Layout(AudioConverterInterop.kAudioChannelLayoutTag_Stereo);
            uint elements = 1;
            uint maxFrames = (uint)_maxFrames;
            uint algorithm = AudioUnitInterop.kSpatializationAlgorithm_UseOutputType;
            uint sourceMode = AudioUnitInterop.kSpatialMixerSourceMode_AmbienceBed;

            bool ok = SpatialProp("输出 StreamFormat（2ch float 非交织）", AudioUnitInterop.kAudioUnitProperty_StreamFormat, AudioUnitInterop.kAudioUnitScope_Output, 0, &output, (uint)sizeof(AudioToolbox.AudioStreamBasicDescription))
                && SpatialProp("输出布局 Stereo", AudioUnitInterop.kAudioUnitProperty_AudioChannelLayout, AudioUnitInterop.kAudioUnitScope_Output, 0, &outputLayout, (uint)sizeof(AudioToolbox.AudioChannelLayout))
                && SpatialProp("输入 StreamFormat（6ch float 非交织）", AudioUnitInterop.kAudioUnitProperty_StreamFormat, AudioUnitInterop.kAudioUnitScope_Input, 0, &input, (uint)sizeof(AudioToolbox.AudioStreamBasicDescription))
                && SpatialProp("输入布局 MPEG_5_1_A", AudioUnitInterop.kAudioUnitProperty_AudioChannelLayout, AudioUnitInterop.kAudioUnitScope_Input, 0, &inputLayout, (uint)sizeof(AudioToolbox.AudioChannelLayout))
                && SpatialProp("输入元件数", AudioUnitInterop.kAudioUnitProperty_ElementCount, AudioUnitInterop.kAudioUnitScope_Input, 0, &elements, sizeof(uint))
                && SpatialProp("MaximumFramesPerSlice", AudioUnitInterop.kAudioUnitProperty_MaximumFramesPerSlice, AudioUnitInterop.kAudioUnitScope_Global, 0, &maxFrames, sizeof(uint))
                && SpatialProp("SpatializationAlgorithm=UseOutputType", AudioUnitInterop.kAudioUnitProperty_SpatializationAlgorithm, AudioUnitInterop.kAudioUnitScope_Input, 0, &algorithm, sizeof(uint))
                && SpatialProp("SpatialMixerSourceMode=AmbienceBed", AudioUnitInterop.kAudioUnitProperty_SpatialMixerSourceMode, AudioUnitInterop.kAudioUnitScope_Input, 0, &sourceMode, sizeof(uint))
                && SpatialProp("SpatialMixerOutputType", AudioUnitInterop.kAudioUnitProperty_SpatialMixerOutputType, AudioUnitInterop.kAudioUnitScope_Global, 0, &outputType, sizeof(uint));

            if (!ok)
            {
                return false;
            }

            // 平面 / 输出缓冲 / 回调：属性都设成功之后才分配，失败路径不留尾巴（Dispose 按「已分配才收」收）
            _self = GCHandle.Alloc(this);
            _spatialInputProc = SpatialInput;
            AudioUnitInterop.AURenderCallbackStruct callback = new()
            {
                InputProc = Marshal.GetFunctionPointerForDelegate(_spatialInputProc),
                InputProcRefCon = GCHandle.ToIntPtr(_self),
            };

            for (int i = 0; i < InputChannels; i++)
            {
                _spatialInPlanes[i] = new float[_maxFrames];
            }

            _spatialOutPlanes = new float*[OutputChannels];
            _spatialOutAbl = Marshal.AllocHGlobal(AudioConverterInterop.AudioBufferListBuffersOffset + OutputChannels * sizeof(AudioConverterInterop.AudioBuffer));

            AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(_spatialOutAbl + AudioConverterInterop.AudioBufferListBuffersOffset);

            for (int i = 0; i < OutputChannels; i++)
            {
                _spatialOutPlanes[i] = (float*)Marshal.AllocHGlobal(_maxFrames * sizeof(float));
                buffer[i].NumberChannels = 1;
                buffer[i].DataByteSize = (uint)(_maxFrames * sizeof(float));
                buffer[i].Data = _spatialOutPlanes[i];
            }

            *(uint*)_spatialOutAbl = OutputChannels;

            return SpatialProp("SetRenderCallback（喂 6 条输入平面）", AudioUnitInterop.kAudioUnitProperty_SetRenderCallback, AudioUnitInterop.kAudioUnitScope_Input, 0, &callback, (uint)sizeof(AudioUnitInterop.AURenderCallbackStruct))
                && SpatialStep("AudioUnitInitialize", AudioUnitInterop.AudioUnitInitialize(_unit));
        }

        // AUSM 的输入回调（喂 6 条 float 平面）：在 AudioUnitRender 之内同线程调，帧数是本次要出的 _spatialFrames
        private static int SpatialInput(nint inRefCon, nint ioActionFlags, nint inTimeStamp, uint inBusNumber, uint inNumberFrames, nint ioData)
        {
            AppleOutputProcessor processor = (AppleOutputProcessor)GCHandle.FromIntPtr(inRefCon).Target;

            if (ioData == nint.Zero)
            {
                return 0;
            }

            int frames = Math.Min((int)inNumberFrames, processor._spatialFrames);
            uint buffers = *(uint*)ioData;
            AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(ioData + AudioConverterInterop.AudioBufferListBuffersOffset);

            for (uint i = 0; i < buffers && i < InputChannels; i++)
            {
                float* destination = (float*)buffer[i].Data;
                float[] source = processor._spatialInPlanes[i];
                int copy = Math.Min(frames, source.Length);

                for (int f = 0; f < copy; f++)
                {
                    destination[f] = source[f];
                }

                buffer[i].DataByteSize = (uint)(copy * sizeof(float));
            }

            return 0;
        }

        public bool Process(ReadOnlySpan<byte> input, Span<byte> output)
        {
            int frames = Math.Min(input.Length / InputBytesPerFrame, output.Length / OutputBytesPerFrame);

            if (frames <= 0)
            {
                return true;
            }

            lock (_lock)
            {
                if (_disposed)
                {
                    return false;
                }

                if (_mode == AppleOutputMode.Matrix)
                {
                    MatrixDownmix(input, output, frames);

                    return true;
                }

                if (_mode == AppleOutputMode.System && ConvertSystem(input, output, frames))
                {
                    return true;
                }

                if ((_mode == AppleOutputMode.SpatialSpeakers || _mode == AppleOutputMode.SpatialHeadphones)
                    && ConvertSpatial(input, output, frames))
                {
                    return true;
                }

                MatrixDownmix(input, output, frames);

                CountFailure(_mode is AppleOutputMode.SpatialSpeakers or AppleOutputMode.SpatialHeadphones
                    ? $"AudioUnitRender rc={_spatialRenderRc}、片长 {_spatialRenderFrames} 帧"
                    : "");

                return false;
            }
        }

        private void CountFailure(string detail)
        {
            _failures++;

            if (_failures == 1)
            {
                Console.Error.WriteLine($"[声] 【红】5.1→2.0 档「{AppleOutputModeSelector.ModeName(_requestedMode)}」这一次没出数：这一片按矩阵下混{(detail.Length > 0 ? $"（{detail}）" : "")}");
            }
        }

        private static void MatrixDownmix(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            ReadOnlySpan<short> source = MemoryMarshal.Cast<byte, short>(input)[..(frames * InputChannels)];
            Span<short> destination = MemoryMarshal.Cast<byte, short>(output)[..(frames * OutputChannels)];

            Downmixing.DownMixSurroundToStereo(source, destination);
        }

        private bool ConvertSystem(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            int remaining = frames;
            int frameOffset = 0;

            while (remaining > 0)
            {
                int chunk = Math.Min(remaining, _maxFrames);
                int inputBytes = chunk * InputBytesPerFrame;
                int outputBytes = chunk * OutputBytesPerFrame;
                bool ok;

                fixed (byte* inputPtr = input.Slice(frameOffset * InputBytesPerFrame, inputBytes))
                fixed (byte* outputPtr = output.Slice(frameOffset * OutputBytesPerFrame, outputBytes))
                {
                    _convInput = (nint)inputPtr;
                    _convFrames = chunk;
                    _convDone = 0;

                    AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(_convOutputAbl + AudioConverterInterop.AudioBufferListBuffersOffset);

                    *(uint*)_convOutputAbl = 1;
                    buffer->NumberChannels = OutputChannels;
                    buffer->DataByteSize = (uint)outputBytes;
                    buffer->Data = outputPtr;

                    uint outputFrames = (uint)chunk;
                    int rc = AudioConverterInterop.AudioConverterFillComplexBuffer(_converter, _convInputProcPtr,
                        GCHandle.ToIntPtr(_self), ref outputFrames, _convOutputAbl, 0);

                    ok = rc == 0 && outputFrames == (uint)chunk;
                }

                if (!ok)
                {
                    return false;
                }

                frameOffset += chunk;
                remaining -= chunk;
            }

            return true;
        }

        private static int ConverterInput(nint converter, ref uint ioPackets, nint ioData, nint packetDescription, nint userData)
        {
            AppleOutputProcessor processor = (AppleOutputProcessor)GCHandle.FromIntPtr(userData).Target;

            if (processor._convDone != 0)
            {
                ioPackets = 0;

                return 0;
            }

            AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(ioData + AudioConverterInterop.AudioBufferListBuffersOffset);

            *(uint*)ioData = 1;
            buffer->NumberChannels = InputChannels;
            buffer->DataByteSize = (uint)(processor._convFrames * InputBytesPerFrame);
            buffer->Data = (void*)processor._convInput;
            processor._convDone = 1;
            ioPackets = (uint)processor._convFrames;

            return 0;
        }

        // S2Arm（#189 后续，虚拟环绕）：6 声道 PCM16 → 6 条 float 平面（÷32768）→ AUSM 渲染（mSampleTime 单调）
        //   → 2 条 float 平面 → PCM16（就近取整 + 截幅）。帧数不变（同 sys / matrix 档），会话的字节账 / 缓冲释放
        //   节奏不变；AUSM 输出没有幅度上限保证，按 PCM16 截幅并把截幅采样计入累计（评审 11-16：进收局统计）
        private bool ConvertSpatial(ReadOnlySpan<byte> input, Span<byte> output, int frames)
        {
            int remaining = frames;
            int frameOffset = 0;
            long clipped = 0;

            while (remaining > 0)
            {
                int chunk = Math.Min(remaining, _maxFrames);

                ReadOnlySpan<short> source = MemoryMarshal.Cast<byte, short>(input.Slice(frameOffset * InputBytesPerFrame, chunk * InputBytesPerFrame));

                for (int channel = 0; channel < InputChannels; channel++)
                {
                    float[] plane = _spatialInPlanes[channel];

                    for (int f = 0; f < chunk; f++)
                    {
                        plane[f] = source[f * InputChannels + channel] / 32768f;
                    }
                }

                _spatialFrames = chunk;

                AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(_spatialOutAbl + AudioConverterInterop.AudioBufferListBuffersOffset);

                for (int channel = 0; channel < OutputChannels; channel++)
                {
                    buffer[channel].DataByteSize = (uint)(chunk * sizeof(float));
                }

                _spatialTimeStamp.SampleTime = _spatialSampleTime;
                _spatialTimeStamp.Flags = AudioUnitInterop.kAudioTimeStampSampleTimeValid;

                uint flags = 0;
                int rc = AudioUnitInterop.AudioUnitRender(_unit, ref flags, ref _spatialTimeStamp, 0, (uint)chunk, _spatialOutAbl);

                if (rc != 0)
                {
                    _spatialRenderRc = rc;
                    _spatialRenderFrames = chunk;

                    return false;
                }

                _spatialSampleTime += chunk;

                Span<short> destination = MemoryMarshal.Cast<byte, short>(output.Slice(frameOffset * OutputBytesPerFrame, chunk * OutputBytesPerFrame));

                for (int f = 0; f < chunk; f++)
                {
                    for (int channel = 0; channel < OutputChannels; channel++)
                    {
                        float value = _spatialOutPlanes[channel][f] * 32768f;
                        int sample = Math.Clamp((int)MathF.Round(value), short.MinValue, short.MaxValue);

                        if (Math.Abs(sample) >= short.MaxValue)
                        {
                            clipped++;
                        }

                        destination[f * OutputChannels + channel] = (short)sample;
                    }
                }

                frameOffset += chunk;
                remaining -= chunk;
            }

            if (clipped > 0)
            {
                Interlocked.Add(ref _clippedSamples, clipped);
            }

            return true;
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;

                if (_converter != 0)
                {
                    AudioConverterInterop.AudioConverterDispose(_converter);
                    _converter = 0;
                }

                if (_unit != 0)
                {
                    AudioUnitInterop.AudioUnitUninitialize(_unit);
                    AudioUnitInterop.AudioComponentInstanceDispose(_unit);
                    _unit = 0;
                }

                if (_spatialOutAbl != 0)
                {
                    if (_spatialOutPlanes != null)
                    {
                        for (int i = 0; i < _spatialOutPlanes.Length; i++)
                        {
                            if (_spatialOutPlanes[i] != null)
                            {
                                Marshal.FreeHGlobal((nint)_spatialOutPlanes[i]);
                                _spatialOutPlanes[i] = null;
                            }
                        }
                    }

                    Marshal.FreeHGlobal(_spatialOutAbl);
                    _spatialOutAbl = 0;
                }

                if (_convOutputAbl != 0)
                {
                    Marshal.FreeHGlobal(_convOutputAbl);
                    _convOutputAbl = 0;
                }

                if (_self.IsAllocated)
                {
                    _self.Free();
                }
            }
        }
    }
}
