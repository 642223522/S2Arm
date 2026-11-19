using Ryujinx.Audio;
using Ryujinx.Audio.Backends.Apple;   // 平台例外：本用例只测 Apple 音频后端（#189 后续，设备类型 + 虚拟环绕），只在 macOS 上跑
using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Pre-boot solo test（#189 后续）：设备类型选择器、驱动上报矩阵、会话路径接线（不出声：会话只建不播）、
        //   AUSM 5.1 判据（处理器级手动拉取，纯 CPU 不出声）。读数基准 = 评估的裸 AUSM 手动渲染表
        //   （48 kHz / 997 Hz / 4800 帧跳过前 1200 帧）：显式 BuiltInSpeakers——FL +7.1 dB、C 等幅、LFE 0.000（移除）、
        //   BL 近等幅（-0.5 dB）；显式 Headphones——FL +8.0 dB、延迟约 0.4–1.4 ms（19–67 样本）、C 等幅、
        //   LFE 受衰减（约 7% 输入）；ExternalSpeakers / .auto——FL 仅左、BL +12.8 dB、0 延迟（普通平移，负对照见坑记录）。
        //   试建队列的 callback 必须非空（macOS 27 起 NULL 直接 -50，#189）
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void DeviceTypesProbeCallback(nint userData, nint audioQueue, nint buffer);

        private static readonly DeviceTypesProbeCallback _deviceTypesProbeCallback = static (_, _, _) => { };

        [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicFields,
            "Ryujinx.Audio.Backends.Apple.AppleHardwareDeviceSession", "Ryujinx.Audio.Backends.Apple")]   // 平台例外：本用例只测 Apple 音频后端的会话接线（#189 后续），只在 macOS 上跑
        [SoloTest("--apple-audio-device-types")]
        internal static int AppleAudioDeviceTypes()
        {
            int failures = 0;

            void Check(string name, bool ok, string detail = "")
            {
                Console.WriteLine($"{(ok ? "通过" : "【红】")} {name}{(detail.Length > 0 ? "：" + detail : "")}");

                if (!ok)
                {
                    failures++;
                }
            }

            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
            {
                Console.WriteLine("【红】Apple 音频后端不可用");
                return 1;
            }

            string oldDevice = Environment.GetEnvironmentVariable("S2A_AUDIO_DEVICE");
            string oldVsSpeakers = Environment.GetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS");
            string oldVsHeadphones = Environment.GetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES");
            string oldCh2 = Environment.GetEnvironmentVariable("S2A_AUDIO_CH2");
            string oldStereo = Environment.GetEnvironmentVariable("S2A_AUDIO_STEREO");
            string oldOut = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");

            void Set(string device, string vsSpeakers, string vsHeadphones)
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", device);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", vsSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES", vsHeadphones);
            }

            bool Reports6()
            {
                using AppleHardwareDeviceDriver driver = new();   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑

                return driver.SupportsChannelCount(6);
            }

            try
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_STEREO", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);

                // ① 设备类型选择器：缺省 Auto（未显式选择 = 按设备自动判，评审 11-16）；显式解析三种类型；非法值回落 Auto
                Set(null, null, null);
                Check("缺省设备类型 = Auto（未显式选择 = 按设备自动）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "auto");
                Check("auto 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "builtin");
                Check("builtin 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "BuiltInSpeakers");
                Check("BuiltInSpeakers 别名（不分大小写）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "speakers");
                Check("speakers 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.BuiltInSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "headphones");
                Check("headphones 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Headphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "Headphone");
                Check("Headphone 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Headphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "external");
                Check("external 解析", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "ExternalSpeakers");
                Check("ExternalSpeakers 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "tv");
                Check("tv 别名", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.ExternalSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", "bogus");
                Check("不认识的设备类型回落 Auto（按设备自动判）", AppleAudioDeviceTypeSelector.FromEnvironment() == AppleAudioDeviceType.Auto);

                // 两个 VS 开关按类型分别读、external 永远关
                Set("builtin", "1", null);
                Check("builtin 的 VS 开（S2A_AUDIO_VS_SPEAKERS=1）", AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", "0", null);
                Check("builtin 的 VS 关（0）", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", null, null);
                Check("builtin 的 VS 缺省关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("builtin", null, "1");
                Check("builtin 不看耳机的 VS 开关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.BuiltInSpeakers));
                Set("headphones", null, "1");
                Check("headphones 的 VS 开（S2A_AUDIO_VS_HEADPHONES=1）", AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Headphones));
                Set("headphones", "1", null);
                Check("headphones 不看扬声器的 VS 开关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Headphones));
                Set("external", "1", "1");
                Check("external 的 VS 永远关", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.ExternalSpeakers));
                Check("Auto 的 VS 永远关（未显式选择不套 VS）", !AppleAudioDeviceTypeSelector.VirtualSurround(AppleAudioDeviceType.Auto));

                // ② 驱动上报矩阵：缺省（未显式选择）按设备真实声道判——期望按 main 的 #577 判据写死（评审 11-16），
                //   用注入的探测读数模拟设备（产品路径不走注入）；显式 builtin / headphones 才看各自 VS 开关
                Set(null, null, null);
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：注入试建读数，模拟 6 声道设备
                Check("未显式选择 + 设备 6 声道 → 上报 5.1（main 的 #577 判据）", Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 2, 0, 0);   // 平台例外：模拟 2 声道设备
                Check("未显式选择 + 设备 2 声道 → 上报 2", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 5, 0);   // 平台例外：模拟声道数读失败
                Check("未显式选择 + 读声道失败 → 上报 2（【红】后保守）", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (-50, 0, -1, -1);   // 平台例外：模拟试建队列失败（macOS 27 的 NULL callback 坑）
                Check("未显式选择 + 试建队列失败 → 上报 2", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 5);   // 平台例外：模拟 5.1 布局设置失败
                Check("未显式选择 + 5.1 布局设置失败 → 上报 2（保守回退）", !Reports6());
                AppleHardwareDeviceDriver.S2ATestProbe = (0, 6, 0, 0);   // 平台例外：6 声道设备
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", "1");
                Check("未显式选择 + 只设 VS 开关 → 仍按设备判报 5.1（VS 只在显式类型生效）", Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", null);
                AppleHardwareDeviceDriver.S2ATestProbe = null;   // 平台例外：清注入，后面的用例走真探测
                Set("builtin", "1", null);
                Check("builtin + VS 开上报 6", Reports6());
                Set("builtin", null, null);
                Check("builtin + VS 关不上报 6", !Reports6());
                Set("builtin", null, "1");
                Check("builtin 只看自己的 VS 开关", !Reports6());
                Set("headphones", null, "1");
                Check("headphones + VS 开上报 6", Reports6());
                Set("headphones", null, null);
                Check("headphones + VS 关不上报 6", !Reports6());
                Set("headphones", "1", null);
                Check("headphones 只看自己的 VS 开关", !Reports6());

                // external：上报 6 ⇔ 默认输出设备真实声道数 ≥ 6；两个 VS 开关都不改变它
                AudioStreamBasicDescription format =
                    AppleHardwareDeviceDriver.GetAudioFormat(SampleFormat.PcmFloat, Constants.TargetSampleRate, 2);   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑

                int newResult = AudioQueueNewOutput(
                    ref format,
                    Marshal.GetFunctionPointerForDelegate(_deviceTypesProbeCallback),
                    nint.Zero, nint.Zero, nint.Zero, 0, out nint queue);

                uint deviceChannels = 0;
                bool readOk = false;

                if (newResult == 0)
                {
                    uint size = sizeof(uint);
                    int getResult = AudioQueueGetProperty(
                        queue, kAudioQueueDeviceProperty_NumberChannels, out deviceChannels, ref size);
                    AudioQueueDispose(queue, true);
                    readOk = getResult == 0;
                    Check("独立读默认输出设备声道数", readOk, $"rc={getResult}");
                }
                else
                {
                    Check("独立读默认输出设备声道数（试建队列）", false, $"AudioQueueNewOutput rc={newResult}");
                }

                if (readOk)
                {
                    Set("external", null, null);
                    Check("external：上报 6 ⇔ 设备 ≥ 6 声道", Reports6() == (deviceChannels >= 6),
                        $"设备 {deviceChannels} 声道（builtin/VS 缺省也不因设备 ≥6 上报 6，VS 开才报）");
                    Set("external", "1", "1");
                    Check("external：两个 VS 开关不改变上报", Reports6() == (deviceChannels >= 6),
                        $"设备 {deviceChannels} 声道（external 不虚拟环绕）");
                }

                // ③ S2A_AUDIO_CH2 仍最高优先级；S2A_AUDIO_OUT=sys 显式下混优先于设备类型
                Set("builtin", "1", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", "1");
                Check("builtin + VS 开 + S2A_AUDIO_CH2=1 仍强制立体声", !Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", null);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", "sys");
                Check("builtin + VS 关 + S2A_AUDIO_OUT=sys 照报 5.1（显式下混优先）", Reports6());
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);

                // ④ 会话路径接线（反射 _processor / _deviceChannelCount；会话只建不播，不出声）
                FieldInfo processorField = typeof(AppleHardwareDeviceSession).GetField("_processor", BindingFlags.NonPublic | BindingFlags.Instance)   // 平台例外：本用例只测 Apple 音频后端的会话接线（#189 后续），只在 macOS 上跑
                    ?? throw new InvalidOperationException("找不到 AppleHardwareDeviceSession._processor");   // 平台例外：同上，只在 macOS 上跑
                FieldInfo deviceChannelsField = typeof(AppleHardwareDeviceSession).GetField("_deviceChannelCount", BindingFlags.NonPublic | BindingFlags.Instance)   // 平台例外：同上，只在 macOS 上跑
                    ?? throw new InvalidOperationException("找不到 AppleHardwareDeviceSession._deviceChannelCount");   // 平台例外：同上，只在 macOS 上跑

                (AppleOutputMode? Mode, int DeviceChannels) Session(AppleAudioDeviceType? type, string vs, SampleFormat sampleFormat)
                {
                    Set(type == AppleAudioDeviceType.BuiltInSpeakers ? "builtin"
                      : type == AppleAudioDeviceType.Headphones ? "headphones"
                      : type == AppleAudioDeviceType.ExternalSpeakers ? "external" : null, vs, vs);

                    using MemoryBlock backing = new(0x1000);
                    var memory = new Ryujinx.Cpu.Jit.MemoryManager(backing, 0x1000);
                    memory.IncrementReferenceCount();

                    try
                    {
                        using AppleHardwareDeviceDriver driver = new();   // 平台例外：本用例只测 Apple 音频后端（#189 后续），只在 macOS 上跑
                        using IHardwareDeviceSession session = driver.OpenDeviceSession(   // 平台例外：同上
                            IHardwareDeviceDriver.Direction.Output, memory, sampleFormat, 48000, 6);
                        AppleOutputProcessor processor = (AppleOutputProcessor)processorField.GetValue(session);

                        return (processor?.EffectiveMode ?? null, (int)deviceChannelsField.GetValue(session));
                    }
                    finally
                    {
                        memory.DecrementReferenceCount();
                    }
                }

                (AppleOutputMode? mode, int sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, "1", SampleFormat.PcmInt16);
                Check("builtin + VS 开 + 6ch PCM16 → AUSM 内置扬声器档（会话折到 2 声道）",
                    mode == AppleOutputMode.SpatialSpeakers && sessionChannels == 2,
                    $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.Headphones, "1", SampleFormat.PcmInt16);
                Check("headphones + VS 开 + 6ch PCM16 → AUSM 耳机档（会话折到 2 声道）",
                    mode == AppleOutputMode.SpatialHeadphones && sessionChannels == 2,
                    $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, null, SampleFormat.PcmInt16);
                Check("builtin + VS 关 → 无处理器、6 声道直交（不套 AUSM）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.Headphones, null, SampleFormat.PcmInt16);
                Check("headphones + VS 关 → 无处理器、6 声道直交",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.ExternalSpeakers, "1", SampleFormat.PcmInt16);
                Check("external + 6ch → 无处理器、6 声道直通队列（VS 无效）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(AppleAudioDeviceType.BuiltInSpeakers, "1", SampleFormat.PcmFloat);
                Check("builtin + VS 开 + 6ch 非 PCM16 → 无处理器（只支持 PCM16 的 5.1）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");
                (mode, sessionChannels) = Session(null, "1", SampleFormat.PcmInt16);
                Check("未显式选择 + 只设 VS 开 + 6ch → 无处理器（VS 只在显式类型生效，走原 6ch 路径）",
                    mode == null && sessionChannels == 6, $"档 {mode?.ToString() ?? "无"}、设备声道 {sessionChannels}");

                // ⑤ AUSM 5.1 判据（处理器级，无声）：裸 AUSM 手动拉取，读数基准见方法头注释
                const int rate = 48000;
                const int frames = 4800;
                const int skip = 1200;
                const float amplitude = 16000.0f;
                double inputRms = amplitude / Math.Sqrt(2.0);

                byte[] Tone(int channel)
                {
                    byte[] data = new byte[frames * 6 * sizeof(short)];
                    Span<short> samples = MemoryMarshal.Cast<byte, short>(data.AsSpan());

                    for (int frame = 0; frame < frames; frame++)
                    {
                        samples[frame * 6 + channel] = (short)MathF.Round(amplitude * MathF.Sin(2.0f * MathF.PI * 997.0f * frame / rate));
                    }

                    return data;
                }

                (double Left, double Right) Rms(byte[] stereo)
                {
                    ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(stereo.AsSpan());
                    double left = 0, right = 0;
                    int count = 0;

                    for (int frame = skip; frame < frames; frame++)
                    {
                        left += (double)samples[frame * 2] * samples[frame * 2];
                        right += (double)samples[frame * 2 + 1] * samples[frame * 2 + 1];
                        count++;
                    }

                    return count > 0 ? (Math.Sqrt(left / count), Math.Sqrt(right / count)) : (0, 0);
                }

                double RatioDb(double left, double right) => 20 * Math.Log10((left + 1e-9) / (right + 1e-9));

                // 左右互相关最佳延迟（样本）：虚拟化（Headphones）非 0，普通平移（.auto / External）为 0
                (double Corr, int Lag) BestLag(byte[] stereo)
                {
                    ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(stereo.AsSpan());
                    double best = -2.0;
                    int bestLag = 0;

                    for (int d = -80; d <= 80; d++)
                    {
                        double sum = 0, energyLeft = 0, energyRight = 0;
                        int count = 0;

                        for (int i = skip; i < frames - skip; i++)
                        {
                            int j = i + d;

                            if (j < 0 || j >= frames)
                            {
                                continue;
                            }

                            double x = samples[i * 2], y = samples[j * 2 + 1];
                            sum += x * y;
                            energyLeft += x * x;
                            energyRight += y * y;
                            count++;
                        }

                        if (count == 0)
                        {
                            continue;
                        }

                        double correlation = sum / (Math.Sqrt(energyLeft * energyRight) + 1e-12);

                        if (correlation > best)
                        {
                            best = correlation;
                            bestLag = d;
                        }
                    }

                    return (best, bestLag);
                }

                double RmsRatio(double rms) => rms / inputRms;

                // 内置扬声器档（显式 BuiltInSpeakers 输出类型）
                using (AppleOutputProcessor speakers = AppleOutputProcessor.Create(AppleOutputMode.SpatialSpeakers, rate, 2400))
                {
                    Check("AUSM BuiltInSpeakers 器件建立", speakers.EffectiveMode == AppleOutputMode.SpatialSpeakers && speakers.InitError == null,
                        speakers.InitError ?? "");

                    if (speakers.EffectiveMode == AppleOutputMode.SpatialSpeakers)
                    {
                        byte[] output = new byte[frames * 2 * sizeof(short)];

                        speakers.Process(Tone(0), output);
                        (double left, double right) = Rms(output);
                        Check("内置扬声器档 FL 左右比 > 4 dB（虚拟化非仅左）", RatioDb(left, right) > 4,
                            $"L/R {RatioDb(left, right):F1} dB、L {RmsRatio(left):F3} R {RmsRatio(right):F3}×输入");

                        speakers.Process(Tone(2), output);
                        (left, right) = Rms(output);
                        Check("内置扬声器档 中置两路等幅", Math.Abs(RatioDb(left, right)) < 1 && left > 0.5 * inputRms && right > 0.5 * inputRms,
                            $"L/R {RatioDb(left, right):F2} dB、L {RmsRatio(left):F3} R {RmsRatio(right):F3}×输入");

                        speakers.Process(Tone(3), output);
                        (left, right) = Rms(output);
                        Check("内置扬声器档 LFE 被移除（实测 0.000×输入）", left < 0.01 * inputRms && right < 0.01 * inputRms,
                            $"L {RmsRatio(left):F4} R {RmsRatio(right):F4}×输入");

                        speakers.Process(Tone(4), output);
                        (left, right) = Rms(output);
                        Check("内置扬声器档 BL 两路近等幅（普通平移是 +12.8 dB）", Math.Abs(RatioDb(left, right)) < 2 && left > 0.5 * inputRms,
                            $"L/R {RatioDb(left, right):F2} dB、L {RmsRatio(left):F3} R {RmsRatio(right):F3}×输入");
                    }
                }

                // 耳机档（显式 Headphones 输出类型）
                using (AppleOutputProcessor headphones = AppleOutputProcessor.Create(AppleOutputMode.SpatialHeadphones, rate, 2400))
                {
                    Check("AUSM Headphones 器件建立", headphones.EffectiveMode == AppleOutputMode.SpatialHeadphones && headphones.InitError == null,
                        headphones.InitError ?? "");

                    if (headphones.EffectiveMode == AppleOutputMode.SpatialHeadphones)
                    {
                        byte[] output = new byte[frames * 2 * sizeof(short)];

                        headphones.Process(Tone(0), output);
                        (double left, double right) = Rms(output);
                        (double corr, int lagFl) = BestLag(output);
                        Check("耳机档 FL 左右比 > 4 dB", RatioDb(left, right) > 4,
                            $"L/R {RatioDb(left, right):F1} dB、L {RmsRatio(left):F3} R {RmsRatio(right):F3}×输入");

                        headphones.Process(Tone(4), output);
                        (left, right) = Rms(output);
                        (corr, int lagBl) = BestLag(output);
                        Check("耳机档 有双耳延迟（FL/BL 之一 |延迟| ≥ 15 样本，普通平移是 0）",
                            Math.Abs(lagFl) >= 15 || Math.Abs(lagBl) >= 15, $"FL {lagFl:+#;-#;0}、BL {lagBl:+#;-#;0} 样本（相关 {corr:F3}）");

                        headphones.Process(Tone(2), output);
                        (left, right) = Rms(output);
                        Check("耳机档 中置两路等幅", Math.Abs(RatioDb(left, right)) < 1 && left > 0.4 * inputRms && right > 0.4 * inputRms,
                            $"L/R {RatioDb(left, right):F2} dB、L {RmsRatio(left):F3} R {RmsRatio(right):F3}×输入");

                        headphones.Process(Tone(3), output);
                        (left, right) = Rms(output);
                        Check("耳机档 LFE 受衰减（非移除）", left > 0.003 * inputRms && left < 0.15 * inputRms && Math.Abs(RatioDb(left, right)) < 1,
                            $"L {RmsRatio(left):F4} R {RmsRatio(right):F4}×输入");

                        // ⑥ 性能读数：ConvertSpatial 在交缓冲的生产方线程上同步跑（评审 11-16），典型片长给
                        //   中位 / 最大；4800 帧一片（50 ms 设备缓冲，两片 2400）有门限 150 µs
                        byte[] bigSlice = new byte[frames * 6 * sizeof(short)];
                        long start = Stopwatch.GetTimestamp();

                        for (int i = 0; i < 100; i++)
                        {
                            headphones.Process(bigSlice, output);
                        }

                        double microseconds = (Stopwatch.GetTimestamp() - start) * 1e6 / Stopwatch.Frequency / 100;
                        Check("AUSM 一片 4800 帧 < 150 µs", microseconds < 150, $"{microseconds:F1} µs（100 ms 音频）");

                        foreach (int sliceFrames in new[] { 240, 480, 1024, 2400 })
                        {
                            byte[] slice = new byte[sliceFrames * 6 * sizeof(short)];
                            byte[] sliceOutput = new byte[sliceFrames * 2 * sizeof(short)];
                            double[] samples = new double[200];

                            for (int i = 0; i < 50; i++)
                            {
                                headphones.Process(slice, sliceOutput);
                            }

                            for (int i = 0; i < samples.Length; i++)
                            {
                                long t0 = Stopwatch.GetTimestamp();
                                headphones.Process(slice, sliceOutput);
                                samples[i] = (Stopwatch.GetTimestamp() - t0) * 1e6 / Stopwatch.Frequency;
                            }

                            Array.Sort(samples);
                            Console.WriteLine($"读数：AUSM 一片 {sliceFrames} 帧（{sliceFrames * 1000.0 / rate:F1} ms 音频）中位 {samples[samples.Length / 2]:F1} µs、最大 {samples[^1]:F1} µs");
                        }
                    }
                }
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_AUDIO_DEVICE", oldDevice);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS", oldVsSpeakers);
                Environment.SetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES", oldVsHeadphones);
                Environment.SetEnvironmentVariable("S2A_AUDIO_CH2", oldCh2);
                Environment.SetEnvironmentVariable("S2A_AUDIO_STEREO", oldStereo);
                Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", oldOut);
            }

            Console.WriteLine(failures == 0 ? "设备类型 + 虚拟环绕：全部通过" : $"设备类型 + 虚拟环绕：{failures} 项失败");

            return failures == 0 ? 0 : 1;
        }
    }
}
