// Audio DSP kernels (compat/tree/src/Ryujinx.Audio/Renderer/Dsp): the S2Arm AdvSimd fast paths (S2A_AUDIO_DSP_FAST,
// default on) must be bit-identical to the upstream scalar loops for every kernel they gate:
//   resample default quality (4 taps) and high quality (8 taps), 5.1 -> stereo downmix, mix ramp, volume ramp,
//   the device-sink float -> int16 saturate + stereo interleave, the 6-channel (5.1) device interleave (TBL gather),
//   the two-channel packed multi-stage biquad (Vector64 lanes, stage 1 fused onto stage 0's lanes), and the
//   ADPCM frame nibble unpack (vector unpack + scale, scalar prediction chain).
// Expected values come from the scalar reference transcribed here from the upstream loops (independent of the
// kernels under test) and, for the mix kernels, also from the tree's own scalar path (S2ADspMixHelper.*Scalar).
// Adversarial inputs: rounding midpoints everywhere (Math.Round default = round-half-to-even: x.5 must round to
// even, not away from zero), 0, +-short.MaxValue/MinValue, NaN and +-Inf (saturate must give 0 / +-32767/-32768),
// ratios on all three LUT boundaries (1.0, 1.333313) and random, fractions spanning the 128 phase slots, sample
// counts with scalar tails (n % 4 == 1..3 for 4-lane kernels, n % 8 == 1..7 for the interleaves), ramps 0 / negative
// / tiny / huge, volume 0, biquad states/inputs with NaN and +-Inf (NaN compared as is-NaN only: the JIT may commute
// scalar adds and pick the other NaN payload, same as upstream's audio_dsp_fast), ADPCM streams with mid-frame
// resumes (odd nibble alignment), int32 overflow in the prediction chain, and the last frame's 7-byte tail that
// falls back to the scalar loop (the 8-byte vector read needs one extra byte).
// The wiring check compares the public dispatchers (ResamplerHelper.Resample, S2ADspMixHelper.*,
// S2ADspBiquadHelper.ProcessBiquadFilterStereo, AdpcmHelper.Decode) against the direct kernel calls / transcribed
// references; it runs green under the default env (fast path on) and under S2A_AUDIO_DSP_FAST=0 (the test script
// runs the binary twice). On non-ARM64 there is no AdvSimd: prints off and returns 0.
using System;
using System.Diagnostics;
using System.Runtime.Intrinsics.Arm;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Common.Memory;

static class P
{
    static int fails, cases;

    static void Fail(string what, long i, string want, string got)
    {
        if (fails++ < 10) Console.WriteLine($"FAIL {what} at {i}: want {want}, got {got}");
    }

    static void CheckFloats(string what, ReadOnlySpan<float> want, ReadOnlySpan<float> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
        {
            if (BitConverter.SingleToInt32Bits(want[i]) != BitConverter.SingleToInt32Bits(got[i]))
            {
                Fail(what, i, $"{want[i]:R} (0x{BitConverter.SingleToInt32Bits(want[i]):X8})", $"{got[i]:R} (0x{BitConverter.SingleToInt32Bits(got[i]):X8})");
                return;
            }
        }
    }

    static void CheckShorts(string what, ReadOnlySpan<short> want, ReadOnlySpan<short> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
        {
            if ((ushort)want[i] != (ushort)got[i])
            {
                Fail(what, i, $"{want[i]} (0x{(ushort)want[i]:X4})", $"{got[i]} (0x{(ushort)got[i]:X4})");
                return;
            }
        }
    }

    static void CheckFloat(string what, float want, float got)
    {
        cases++;
        if (BitConverter.SingleToInt32Bits(want) != BitConverter.SingleToInt32Bits(got))
        {
            Fail(what, 0, $"{want:R} (0x{BitConverter.SingleToInt32Bits(want):X8})", $"{got:R} (0x{BitConverter.SingleToInt32Bits(got):X8})");
        }
    }

    // ---- upstream scalar loops, transcribed (do not call the kernels under test) -------------------

    static void RefResampleDefault(ReadOnlySpan<short> input, ReadOnlySpan<float> par, float ratio, float fraction, int sampleCount, Span<float> output, out float outFraction)
    {
        int inputBufferIndex = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            int baseIndex = (int)(fraction * 128) * 4;
            ReadOnlySpan<float> parameter = par.Slice(baseIndex, 4);
            ReadOnlySpan<short> currentInput = input.Slice(inputBufferIndex, 4);

            output[i] = (float)Math.Round(currentInput[0] * parameter[0] +
                                          currentInput[1] * parameter[1] +
                                          currentInput[2] * parameter[2] +
                                          currentInput[3] * parameter[3]);

            fraction += ratio;
            inputBufferIndex += (int)fraction;

            // Only keep lower part (safe as fraction isn't supposed to be negative)
            fraction -= (int)fraction;
        }

        outFraction = fraction;
    }

    static void RefResampleHigh(ReadOnlySpan<short> input, ReadOnlySpan<float> par, float ratio, float fraction, int sampleCount, Span<float> output, out float outFraction)
    {
        int inputBufferIndex = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            int baseIndex = (int)(fraction * 128) * 8;
            ReadOnlySpan<float> parameter = par.Slice(baseIndex, 8);
            ReadOnlySpan<short> currentInput = input.Slice(inputBufferIndex, 8);

            output[i] = (float)Math.Round(currentInput[0] * parameter[0] +
                                          currentInput[1] * parameter[1] +
                                          currentInput[2] * parameter[2] +
                                          currentInput[3] * parameter[3] +
                                          currentInput[4] * parameter[4] +
                                          currentInput[5] * parameter[5] +
                                          currentInput[6] * parameter[6] +
                                          currentInput[7] * parameter[7]);

            fraction += ratio;
            inputBufferIndex += (int)MathF.Truncate(fraction);

            fraction -= (int)fraction;
        }

        outFraction = fraction;
    }

    static void RefDownMix(Span<float> stereoLeft, Span<float> stereoRight, ReadOnlySpan<float> frontLeft, ReadOnlySpan<float> frontRight, ReadOnlySpan<float> frontCenter, ReadOnlySpan<float> lowFrequency, ReadOnlySpan<float> backLeft, ReadOnlySpan<float> backRight, ReadOnlySpan<float> c, int sampleCount)
    {
        for (int i = 0; i < sampleCount; i++)
        {
            stereoLeft[i] = MathF.Round(c[3] * backLeft[i] + c[2] * lowFrequency[i] + c[1] * frontCenter[i] + c[0] * frontLeft[i]);
            stereoRight[i] = MathF.Round(c[3] * backRight[i] + c[2] * lowFrequency[i] + c[1] * frontCenter[i] + c[0] * frontRight[i]);
        }
    }

    static float RefMixRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
    {
        float state = 0;

        for (int i = 0; i < sampleCount; i++)
        {
            state = MathF.Round(inputBuffer[i] * volume);

            outputBuffer[i] += state;
            volume += ramp;
        }

        return state;
    }

    static void RefVolumeRamp(Span<float> outputBuffer, ReadOnlySpan<float> inputBuffer, float volume, float ramp, int sampleCount)
    {
        for (int i = 0; i < sampleCount; i++)
        {
            outputBuffer[i] = MathF.Round(inputBuffer[i] * volume);
            volume += ramp;
        }
    }

    static short RefSaturate(float value)
    {
        if (value > short.MaxValue)
        {
            return short.MaxValue;
        }

        if (value < short.MinValue)
        {
            return short.MinValue;
        }

        return (short)value;
    }

    static void RefSaturateInterleave(Span<short> outputBuffer, ReadOnlySpan<float> left, ReadOnlySpan<float> right, int sampleCount)
    {
        for (int j = 0; j < sampleCount; j++)
        {
            outputBuffer[j * 2] = RefSaturate(left[j]);
            outputBuffer[j * 2 + 1] = RefSaturate(right[j]);
        }
    }

    // ---- helpers ------------------------------------------------------------------------------------

    static short[] FillShorts(Random rnd, int length, int pattern)
    {
        short[] input = new short[length];

        switch (pattern)
        {
            case 1:
                for (int i = 0; i < length; i++) input[i] = (short)rnd.Next(short.MinValue, short.MaxValue);
                break;
            case 2:
                Array.Fill(input, short.MaxValue);
                break;
            case 3:
                Array.Fill(input, short.MinValue);
                break;
            case 4:
                for (int i = 0; i < length; i++) input[i] = (i & 1) == 0 ? short.MaxValue : short.MinValue;
                break;
            default:
                Array.Fill(input, (short)0);
                break;
        }

        return input;
    }

    static float[] Midpoints(int length, int offset)
    {
        // x.x5 values: with volume / coefficient 1.0 every product lands on a rounding midpoint
        float[] a = new float[length];
        for (int i = 0; i < length; i++) a[i] = (i + offset) - 10.5f;
        return a;
    }

    // ---- kernel tests --------------------------------------------------------------------------------

    static void TestResample(Random rnd, bool high)
    {
        string what = high ? "resample high" : "resample default";
        int[] counts = [1, 2, 3, 4, 5, 7, 8, 9, 12, 15, 31, 239, 240, 241, 242, 243, 247];
        float[] ratios = [0.5f, 0.75f, 0.9f, 1.0f, 1.1f, 1.333313f, 1.333314f, 1.5f, 2.0f, 3.7f];

        foreach (float ratio in ratios)
        {
            ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);

            foreach (int n in counts)
            {
                for (int pattern = 0; pattern < 5; pattern++)
                {
                    short[] input = FillShorts(rnd, ((int)ratio + 2) * n + 32, pattern);
                    float[] want = new float[n], got = new float[n];
                    float fraction = rnd.NextSingle();

                    float fracOut;
                    if (high)
                    {
                        RefResampleHigh(input, par, ratio, fraction, n, want, out fracOut);
                    }
                    else
                    {
                        RefResampleDefault(input, par, ratio, fraction, n, want, out fracOut);
                    }

                    float fracVec = fraction;
                    if (high)
                    {
                        ResamplerHelper.ResampleHighQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
                    }
                    else
                    {
                        ResamplerHelper.ResampleDefaultQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
                    }

                    CheckFloats($"{what} n={n} ratio={ratio} pattern={pattern} vs ref", want, got);
                    CheckFloat($"{what} n={n} ratio={ratio} pattern={pattern} fraction", fracOut, fracVec);
                }
            }
        }

        for (int round = 0; round < 400; round++)
        {
            float ratio = MathF.Round(0.25f + rnd.NextSingle() * 3.75f, 3);
            ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);
            int n = rnd.Next(1, 248);
            short[] input = FillShorts(rnd, ((int)ratio + 2) * n + 32, 1);
            float[] want = new float[n], got = new float[n];
            float fraction = round == 0 ? 0f : rnd.NextSingle();

            float fracOut;
            if (high)
            {
                RefResampleHigh(input, par, ratio, fraction, n, want, out fracOut);
            }
            else
            {
                RefResampleDefault(input, par, ratio, fraction, n, want, out fracOut);
            }

            float fracVec = fraction;
            if (high)
            {
                ResamplerHelper.ResampleHighQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
            }
            else
            {
                ResamplerHelper.ResampleDefaultQualityAdvSimd(got, input, ratio, ref fracVec, n, par);
            }

            CheckFloats($"{what} n={n} ratio={ratio} random", want, got);
            CheckFloat($"{what} n={n} ratio={ratio} fraction random", fracOut, fracVec);
        }
    }

    static void TestDownMix(Random rnd)
    {
        float[][] coeffSets =
        [
            [1.0f, 1.0f, 1.0f, 1.0f],
            [0.70710677f, 0.70710677f, 0.70710677f, 0.70710677f],
            [1.0f, 0.5f, 0.25f, 0.75f],
            [0.0f, 0.0f, 0.0f, 0.0f],
            [-1.0f, 2.0f, -0.5f, 1.5f],
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 7, 239, 240, 241, 242, 243, 247];

        for (int round = 0; round < 260; round++)
        {
            int n = counts[round % counts.Length];
            float[] c = coeffSets[round % coeffSets.Length];
            if (round % 3 == 2)
            {
                c = [rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f, rnd.NextSingle() * 3f - 1.5f];
            }

            float[][] ch = new float[6][];
            for (int k = 0; k < 6; k++)
            {
                ch[k] = new float[n];
            }

            if (round % 4 == 1)
            {
                // midpoints: coefficient 1.0 set turns every sample into a x.5 rounding case
                for (int k = 0; k < 6; k++) ch[k] = Midpoints(n, k);
            }
            else if (round % 4 == 2)
            {
                for (int k = 0; k < 6; k++)
                    for (int i = 0; i < n; i++)
                        ch[k][i] = (i & 1) == 0 ? 3e38f : -3e38f;
            }
            else if (round % 4 == 3)
            {
                for (int k = 0; k < 6; k++) Array.Fill(ch[k], 0f);
            }
            else
            {
                for (int k = 0; k < 6; k++)
                    for (int i = 0; i < n; i++)
                        ch[k][i] = rnd.NextSingle() * 4f - 2f;
            }

            float[] wantL = new float[n], wantR = new float[n];
            RefDownMix(wantL, wantR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, n);

            float[] gotL = new float[n], gotR = new float[n];
            S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(gotL, gotR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, n);
            CheckFloats($"downmix n={n} left vs ref", wantL, gotL);
            CheckFloats($"downmix n={n} right vs ref", wantR, gotR);

            float[] slowL = new float[n], slowR = new float[n];
            S2ADspMixHelper.DownMixSurroundToStereoScalar(slowL, slowR, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], c, 0, n);
            CheckFloats($"downmix n={n} left vs scalar", slowL, gotL);
            CheckFloats($"downmix n={n} right vs scalar", slowR, gotR);
        }
    }

    static void TestRamp(Random rnd)
    {
        (float Volume, float Ramp)[] ramps =
        [
            (1.0f, 0.0f),
            (0.5f, 0.5f),
            (0.0f, 0.1f),
            (-2.5f, 0.25f),
            (0.9f, -0.0133333337f),
            (0.75f, 1e-07f),
            (100.5f, -0.25f),
            (1.0f, float.MinValue),
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 7, 239, 240, 241, 242, 243, 247];

        for (int round = 0; round < 240; round++)
        {
            int n = counts[round % counts.Length];
            (float volume, float ramp) = ramps[(round / counts.Length) % ramps.Length];

            float[] input = new float[n];
            float[] output = new float[n];

            switch (round % 5)
            {
                case 1:
                    input = Midpoints(n, 0);
                    break;
                case 2:
                    Array.Fill(input, 0f);
                    break;
                case 3:
                    for (int i = 0; i < n; i++) input[i] = (i & 1) == 0 ? 3e38f : -3e38f;
                    break;
                default:
                    for (int i = 0; i < n; i++) input[i] = rnd.NextSingle() * 4f - 2f;
                    break;
            }

            for (int i = 0; i < n; i++) output[i] = rnd.NextSingle() * 2f - 1f; // accumulation: pre-fill, not zero

            float[] mixWant = (float[])output.Clone();
            float mixWantState = RefMixRamp(mixWant, input, volume, ramp, n);

            float[] mixGot = (float[])output.Clone();
            float mixGotState = S2ADspMixHelper.MixRampAdvSimd(mixGot, input, volume, ramp, n);
            CheckFloats($"mixramp n={n} v={volume:R} r={ramp:R} vs ref", mixWant, mixGot);
            CheckFloat($"mixramp n={n} v={volume:R} r={ramp:R} state vs ref", mixWantState, mixGotState);

            float[] mixSlow = (float[])output.Clone();
            float mixSlowState = S2ADspMixHelper.MixRampScalar(mixSlow, input, volume, ramp, 0, n);
            CheckFloats($"mixramp n={n} v={volume:R} r={ramp:R} vs scalar", mixSlow, mixGot);
            CheckFloat($"mixramp n={n} v={volume:R} r={ramp:R} state vs scalar", mixSlowState, mixGotState);

            float[] volWant = new float[n];
            RefVolumeRamp(volWant, input, volume, ramp, n);

            float[] volGot = new float[n];
            S2ADspMixHelper.VolumeRampAdvSimd(volGot, input, volume, ramp, n);
            CheckFloats($"volumeramp n={n} v={volume:R} r={ramp:R} vs ref", volWant, volGot);

            float[] volSlow = new float[n];
            S2ADspMixHelper.VolumeRampScalar(volSlow, input, volume, ramp, 0, n);
            CheckFloats($"volumeramp n={n} v={volume:R} r={ramp:R} vs scalar", volSlow, volGot);
        }
    }

    static void TestSaturateInterleave(Random rnd)
    {
        float[] specials =
        [
            0f, float.Epsilon, -float.Epsilon, 0.5f, 1.5f, 2.5f, 3.5f, -0.5f, -1.5f, -2.5f, -3.5f,
            2.4999f, 32766.5f, 32766.9f, 32767f, 32767.4f, 32767.5f, 32767.9f, 32768f, 40000.9f, 3e38f, float.MaxValue,
            -32767.5f, -32768f, -32768.5f, -40000.9f, -3e38f, float.MinValue, -0.4f,
            float.NaN, float.PositiveInfinity, float.NegativeInfinity,
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 240, 241, 242, 243, 244, 245, 246, 247];

        for (int round = 0; round < 160; round++)
        {
            int n = counts[round % counts.Length];

            float[] left = new float[n], right = new float[n];
            if (round % 3 == 0)
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = specials[(j * 7 + round) % specials.Length];
                    right[j] = specials[(j * 5 + round * 3) % specials.Length];
                }
            }
            else if (round % 3 == 1)
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = rnd.Next(-33000, 33000);
                    right[j] = rnd.Next(-33000, 33000);
                }
            }
            else
            {
                for (int j = 0; j < n; j++)
                {
                    left[j] = rnd.NextSingle() * 80000f - 40000f;
                    right[j] = rnd.NextSingle() * 80000f - 40000f;
                }
            }

            short[] want = new short[n * 2];
            RefSaturateInterleave(want, left, right, n);

            short[] got = new short[n * 2];
            S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(got, left, right, n);
            CheckShorts($"saturate-interleave n={n} round={round}", want, got);

            short[] slow = new short[n * 2];
            S2ADspMixHelper.SaturateInterleaveStereoScalar(slow, left, right, 0, n);
            CheckShorts($"saturate-interleave n={n} round={round} vs scalar", want, slow);
        }
    }

    static void TestWiring(Random rnd)
    {
        string mode = S2ADspFast.On ? "fast" : "slow";

        // Resample dispatchers (both qualities) against the direct kernel / transcribed reference
        foreach (float ratio in new float[] { 0.9f, 1.0f, 1.4f })
        {
            foreach (int n in new int[] { 239, 240, 241 })
            {
                foreach (bool high in new bool[] { false, true })
                {
                    ReadOnlySpan<float> par = high ? ResamplerHelper.GetHighParameter(ratio) : ResamplerHelper.GetDefaultParameter(ratio);
                    short[] srcInput = FillShorts(rnd, ((int)ratio + 2) * n + 32, 1);

                    float startFraction = rnd.NextSingle();

                    float[] disp = new float[n];
                    float dispFraction = startFraction;
                    ResamplerHelper.Resample(
                        disp, srcInput, ratio, ref dispFraction, n,
                        high ? SampleRateConversionQuality.High : SampleRateConversionQuality.Default,
                        needPitch: false);

                    float[] want = new float[n];
                    float wantFraction = startFraction;
                    if (S2ADspFast.On)
                    {
                        if (high)
                        {
                            ResamplerHelper.ResampleHighQualityAdvSimd(want, srcInput, ratio, ref wantFraction, n, par);
                        }
                        else
                        {
                            ResamplerHelper.ResampleDefaultQualityAdvSimd(want, srcInput, ratio, ref wantFraction, n, par);
                        }
                    }
                    else
                    {
                        if (high)
                        {
                            RefResampleHigh(srcInput, par, ratio, startFraction, n, want, out wantFraction);
                        }
                        else
                        {
                            RefResampleDefault(srcInput, par, ratio, startFraction, n, want, out wantFraction);
                        }
                    }

                    CheckFloats($"wiring resample {mode} n={n} ratio={ratio} high={high}", want, disp);
                    CheckFloat($"wiring resample {mode} n={n} ratio={ratio} high={high} fraction", wantFraction, dispFraction);
                }
            }
        }

        // Mix kernel dispatchers
        const int n2 = 241;
        float[] input = new float[n2], prefill = new float[n2];
        for (int i = 0; i < n2; i++)
        {
            input[i] = rnd.NextSingle() * 4f - 2f;
            prefill[i] = rnd.NextSingle() * 2f - 1f;
        }

        float[] dispMix = (float[])prefill.Clone();
        float dispState = S2ADspMixHelper.MixRamp(dispMix, input, 0.25f, 0.001f, n2);

        float[] wantMix = (float[])prefill.Clone();
        float wantState = S2ADspFast.On ? S2ADspMixHelper.MixRampAdvSimd(wantMix, input, 0.25f, 0.001f, n2) : S2ADspMixHelper.MixRampScalar(wantMix, input, 0.25f, 0.001f, 0, n2);
        CheckFloats($"wiring mixramp {mode}", wantMix, dispMix);
        CheckFloat($"wiring mixramp state {mode}", wantState, dispState);

        float[] dispVol = new float[n2];
        S2ADspMixHelper.VolumeRamp(dispVol, input, 0.75f, -0.001f, n2);
        float[] wantVol = new float[n2];
        if (S2ADspFast.On) S2ADspMixHelper.VolumeRampAdvSimd(wantVol, input, 0.75f, -0.001f, n2);
        else S2ADspMixHelper.VolumeRampScalar(wantVol, input, 0.75f, -0.001f, 0, n2);
        CheckFloats($"wiring volumeramp {mode}", wantVol, dispVol);

        float[] downIn = new float[n2];
        for (int i = 0; i < n2; i++) downIn[i] = rnd.NextSingle() - 0.5f;
        float[] dispL = new float[n2], dispR = new float[n2];
        float[] stereoL = new float[n2], stereoR = new float[n2];
        float[] coeffs = [0.70710677f, 0.5f, 0.25f, 0.70710677f];
        ReadOnlySpan<float> coefficients = coeffs;
        S2ADspMixHelper.DownMixSurroundToStereo(dispL, dispR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, n2);
        if (S2ADspFast.On) S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(stereoL, stereoR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, n2);
        else S2ADspMixHelper.DownMixSurroundToStereoScalar(stereoL, stereoR, downIn, downIn, downIn, downIn, downIn, downIn, coefficients, 0, n2);
        CheckFloats($"wiring downmix {mode} left", stereoL, dispL);
        CheckFloats($"wiring downmix {mode} right", stereoR, dispR);

        short[] dispOut = new short[n2 * 2];
        S2ADspMixHelper.SaturateInterleaveStereo(dispOut, downIn, input, n2);
        short[] wantOut = new short[n2 * 2];
        if (S2ADspFast.On) S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(wantOut, downIn, input, n2);
        else S2ADspMixHelper.SaturateInterleaveStereoScalar(wantOut, downIn, input, 0, n2);
        CheckShorts($"wiring saturate-interleave {mode}", wantOut, dispOut);

        // Biquad stereo dispatcher (two channels packed in vector lanes; fallback = per-channel multi-stage loop)
        BiquadFilterParameter2[] bqParams =
        [
            MakeBiquadParameter(0.9f, -0.4f, 0.2f, 0.3f, -0.1f),
            MakeBiquadParameter(0.7f, 0.25f, -0.125f, -0.2f, 0.05f),
        ];
        var dispBqStates0 = new BiquadFilterState[2];
        var dispBqStates1 = new BiquadFilterState[2];
        foreach (var st in new[] { dispBqStates0, dispBqStates1 })
        {
            for (int i = 0; i < 2; i++)
            {
                st[i].State0 = 0.1f;
                st[i].State1 = -0.2f;
                st[i].State2 = 0.3f;
                st[i].State3 = -0.4f;
            }
        }

        float[] dispBq0 = new float[n2], dispBq1 = new float[n2];
        var wantBqStates0 = (BiquadFilterState[])dispBqStates0.Clone();
        var wantBqStates1 = (BiquadFilterState[])dispBqStates1.Clone();
        S2ADspBiquadHelper.ProcessBiquadFilterStereo(bqParams, dispBqStates0, dispBqStates1, dispBq0, dispBq1, downIn, input, n2);
        float[] wantBq0 = new float[n2], wantBq1 = new float[n2];
        if (S2ADspFast.On)
        {
            S2ADspBiquadHelper.ProcessBiquadFilterStereoAdvSimd(bqParams, wantBqStates0, wantBqStates1, wantBq0, wantBq1, downIn, input, n2);
        }
        else
        {
            S2ADspBiquadHelper.ProcessBiquadFilterStereoScalar(bqParams, wantBqStates0, wantBqStates1, wantBq0, wantBq1, downIn, input, n2);
        }
        CheckFloats($"wiring biquad stereo {mode} out0", wantBq0, dispBq0);
        CheckFloats($"wiring biquad stereo {mode} out1", wantBq1, dispBq1);
        for (int i = 0; i < 2; i++)
        {
            CheckState($"wiring biquad stereo {mode} ch0 stage{i}", wantBqStates0[i], dispBqStates0[i], false);
            CheckState($"wiring biquad stereo {mode} ch1 stage{i}", wantBqStates1[i], dispBqStates1[i], false);
        }

        // 6-channel device interleave dispatcher
        short[] disp6 = new short[n2 * 6];
        S2ADspMixHelper.SaturateInterleave6(disp6, downIn, input, downIn, input, downIn, input, n2);
        short[] want6 = new short[n2 * 6];
        if (S2ADspFast.On) S2ADspMixHelper.SaturateInterleave6AdvSimd(want6, downIn, input, downIn, input, downIn, input, n2);
        else S2ADspMixHelper.SaturateInterleave6Scalar(want6, downIn, input, downIn, input, downIn, input, 0, n2);
        CheckShorts($"wiring saturate-interleave6 {mode}", want6, disp6);
    }

    // ---- new kernels: biquad stereo packing / adpcm frame unpack / 6ch device interleave ------------

    // NaN payload may differ between the scalar and vector paths (the JIT may commute scalar adds and pick the
    // other NaN operand); compare NaN as is-NaN only, like upstream's audio_dsp_fast.
    static void CheckFloatsAnyNan(string what, ReadOnlySpan<float> want, ReadOnlySpan<float> got)
    {
        cases++;
        for (int i = 0; i < want.Length; i++)
        {
            bool wantNaN = float.IsNaN(want[i]);
            if (wantNaN != float.IsNaN(got[i]) || (!wantNaN && BitConverter.SingleToInt32Bits(want[i]) != BitConverter.SingleToInt32Bits(got[i])))
            {
                Fail(what, i, $"{want[i]:R} (0x{BitConverter.SingleToInt32Bits(want[i]):X8})", $"{got[i]:R} (0x{BitConverter.SingleToInt32Bits(got[i]):X8})");
                return;
            }
        }
    }

    static bool CheckState(string what, BiquadFilterState want, BiquadFilterState got, bool anyNaN)
    {
        cases++;
        for (int f = 0; f < 4; f++)
        {
            float w = f switch { 0 => want.State0, 1 => want.State1, 2 => want.State2, _ => want.State3 };
            float g = f switch { 0 => got.State0, 1 => got.State1, 2 => got.State2, _ => got.State3 };
            bool bad = anyNaN ? float.IsNaN(w) != float.IsNaN(g) : BitConverter.SingleToInt32Bits(w) != BitConverter.SingleToInt32Bits(g);
            if (bad)
            {
                Fail($"{what} state{f}", 0, $"{w:R}", $"{g:R}");
                return false;
            }
        }
        return true;
    }

    // upstream multi-stage biquad loop, transcribed (two channels x two stages, stage k>0 reads the output buffer)
    static void RefBiquadStereo(BiquadFilterParameter2[] parameters, BiquadFilterState[] states0, BiquadFilterState[] states1, float[] input0, float[] input1, float[] output0, float[] output1, int n)
    {
        for (int ch = 0; ch < 2; ch++)
        {
            float[] input = ch == 0 ? input0 : input1;
            float[] output = ch == 0 ? output0 : output1;
            BiquadFilterState[] states = ch == 0 ? states0 : states1;

            for (int stageIndex = 0; stageIndex < 2; stageIndex++)
            {
                Span<float> numeratorSpan = parameters[stageIndex].Numerator.AsSpan();
                Span<float> denominatorSpan = parameters[stageIndex].Denominator.AsSpan();

                float a0 = numeratorSpan[0], a1 = numeratorSpan[1], a2 = numeratorSpan[2];
                float b1 = denominatorSpan[0], b2 = denominatorSpan[1];
                float s0 = states[stageIndex].State0, s1 = states[stageIndex].State1, s2 = states[stageIndex].State2, s3 = states[stageIndex].State3;
                float[] src = stageIndex != 0 ? output : input;

                for (int i = 0; i < n; i++)
                {
                    float x = src[i];
                    float y = x * a0 + s0 * a1 + s1 * a2 + s2 * b1 + s3 * b2;

                    s1 = s0; s0 = x; s3 = s2; s2 = y;

                    output[i] = y;
                }

                states[stageIndex].State0 = s0;
                states[stageIndex].State1 = s1;
                states[stageIndex].State2 = s2;
                states[stageIndex].State3 = s3;
            }
        }
    }

    static BiquadFilterParameter2 MakeBiquadParameter(float n0, float n1, float n2, float d0, float d1)
    {
        var parameter = new BiquadFilterParameter2 { Enable = true, Numerator = new Array3<float>(), Denominator = new Array2<float>() };
        parameter.Numerator.AsSpan()[0] = n0;
        parameter.Numerator.AsSpan()[1] = n1;
        parameter.Numerator.AsSpan()[2] = n2;
        parameter.Denominator.AsSpan()[0] = d0;
        parameter.Denominator.AsSpan()[1] = d1;
        return parameter;
    }

    static void TestBiquadStereo(Random rnd)
    {
        int[] counts = [0, 1, 2, 3, 4, 5, 7, 8, 15, 31, 239, 240, 241, 247];

        // special parameter sets: unity passthrough, zero coefficients, huge/tiny/NaN coefficients
        BiquadFilterParameter2[][] parameterSets =
        [
            [MakeBiquadParameter(1f, 0f, 0f, 0f, 0f), MakeBiquadParameter(1f, 0f, 0f, 0f, 0f)],
            [MakeBiquadParameter(0f, 0f, 0f, 0f, 0f), MakeBiquadParameter(0.5f, 0.25f, 0.125f, -0.3f, 0.1f)],
            [MakeBiquadParameter(float.NaN, 1e30f, -1e30f, 1e-30f, 2f), MakeBiquadParameter(1f, float.PositiveInfinity, 0f, float.NegativeInfinity, 1e38f)],
        ];

        for (int round = 0; round < 240; round++)
        {
            int n = counts[round % counts.Length];
            bool anyNaN = round % 8 == 5;
            bool inPlace = round % 5 == 4;

            BiquadFilterParameter2[] parameters;
            if (round % 3 == 2)
            {
                parameters =
                [
                    MakeBiquadParameter(rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 2f - 1f, rnd.NextSingle() * 2f - 1f),
                    MakeBiquadParameter(rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 4f - 2f, rnd.NextSingle() * 2f - 1f, rnd.NextSingle() * 2f - 1f),
                ];
            }
            else
            {
                parameters = parameterSets[round % parameterSets.Length];
            }

            float[] in0 = new float[n], in1 = new float[n];
            if (anyNaN)
            {
                for (int i = 0; i < n; i++)
                {
                    in0[i] = i % 5 == 0 ? float.NaN : (i % 5 == 1 ? float.PositiveInfinity : rnd.NextSingle() * 4f - 2f);
                    in1[i] = i % 7 == 0 ? float.NegativeInfinity : (i % 7 == 3 ? float.NaN : rnd.NextSingle() * 4f - 2f);
                }
            }
            else
            {
                for (int i = 0; i < n; i++)
                {
                    in0[i] = rnd.NextSingle() * 4f - 2f;
                    in1[i] = rnd.NextSingle() * 4f - 2f;
                }
            }

            // initial states snapshot: each path runs from the same states (the kernels write them back in place)
            BiquadFilterState[] initStates0 = new BiquadFilterState[2], initStates1 = new BiquadFilterState[2];
            foreach (var st in new[] { initStates0, initStates1 })
            {
                foreach (ref var s in st.AsSpan())
                {
                    s.State0 = rnd.NextSingle() * 4f - 2f;
                    s.State1 = anyNaN && rnd.NextSingle() < 0.2f ? float.NaN : rnd.NextSingle() * 4f - 2f;
                    s.State2 = rnd.NextSingle() * 4f - 2f;
                    s.State3 = rnd.NextSingle() * 4f - 2f;
                }
            }

            BiquadFilterState[] refStates0 = (BiquadFilterState[])initStates0.Clone(), refStates1 = (BiquadFilterState[])initStates1.Clone();
            float[] refOut0, refOut1;
            if (inPlace)
            {
                refOut0 = (float[])in0.Clone();
                refOut1 = (float[])in1.Clone();
                RefBiquadStereo(parameters, refStates0, refStates1, refOut0, refOut1, refOut0, refOut1, n);
            }
            else
            {
                refOut0 = new float[n];
                refOut1 = new float[n];
                RefBiquadStereo(parameters, refStates0, refStates1, in0, in1, refOut0, refOut1, n);
            }
            // #1182 restart rule (both paths): a stage whose state ends non-finite restarts from zero
            for (int k = 0; k < 2; k++) { RefClearNonFinite(ref refStates0[k]); RefClearNonFinite(ref refStates1[k]); }

            // tree scalar path (the dispatcher's fallback)
            BiquadFilterState[] scalarStates0 = (BiquadFilterState[])initStates0.Clone(), scalarStates1 = (BiquadFilterState[])initStates1.Clone();
            float[] scalarOut0 = (float[])in0.Clone(), scalarOut1 = (float[])in1.Clone();
            S2ADspBiquadHelper.ProcessBiquadFilterStereoScalar(parameters, scalarStates0, scalarStates1, scalarOut0, scalarOut1, in0, in1, (uint)n);
            if (anyNaN)
            {
                CheckFloatsAnyNan($"biquad stereo n={n} r={round} scalar vs ref out0", refOut0, scalarOut0);
                CheckFloatsAnyNan($"biquad stereo n={n} r={round} scalar vs ref out1", refOut1, scalarOut1);
            }
            else
            {
                CheckFloats($"biquad stereo n={n} r={round} scalar vs ref out0", refOut0, scalarOut0);
                CheckFloats($"biquad stereo n={n} r={round} scalar vs ref out1", refOut1, scalarOut1);
            }

            // vector kernel
            BiquadFilterState[] vecStates0 = (BiquadFilterState[])initStates0.Clone(), vecStates1 = (BiquadFilterState[])initStates1.Clone();
            float[] vecOut0 = (float[])in0.Clone(), vecOut1 = (float[])in1.Clone();
            if (inPlace)
            {
                S2ADspBiquadHelper.ProcessBiquadFilterStereoAdvSimd(parameters, vecStates0, vecStates1, vecOut0, vecOut1, vecOut0, vecOut1, (uint)n);
            }
            else
            {
                S2ADspBiquadHelper.ProcessBiquadFilterStereoAdvSimd(parameters, vecStates0, vecStates1, vecOut0, vecOut1, in0, in1, (uint)n);
            }

            string what = $"biquad stereo n={n} r={round} inPlace={inPlace}";
            if (anyNaN)
            {
                CheckFloatsAnyNan($"{what} vs ref out0", refOut0, vecOut0);
                CheckFloatsAnyNan($"{what} vs ref out1", refOut1, vecOut1);
            }
            else
            {
                CheckFloats($"{what} vs ref out0", refOut0, vecOut0);
                CheckFloats($"{what} vs ref out1", refOut1, vecOut1);
            }
            CheckState($"{what} ch0 stage0", refStates0[0], vecStates0[0], anyNaN);
            CheckState($"{what} ch0 stage1", refStates0[1], vecStates0[1], anyNaN);
            CheckState($"{what} ch1 stage0", refStates1[0], vecStates1[0], anyNaN);
            CheckState($"{what} ch1 stage1", refStates1[1], vecStates1[1], anyNaN);
        }
    }

    // ---- #1182 non-finite states: long multi-call runs, state carried across calls (production: 240 samples per call, in place) ----
    // Spec (both paths): at the end of each call, a stage whose state holds a NaN / Inf restarts from zero; without that, one bad
    //   sample silences the voice for good, because by IEEE rules NaN * c = NaN and Inf * 0 = NaN, Inf + -Inf = NaN: once a state
    //   field is NaN, y = x*a0 + s0*a1 + s1*a2 + s2*b1 + s3*b2 is NaN for every later input and the device sink saturates NaN to 0.
    // Expected values do not come from the kernels under test:
    //   - a double-precision reference (same direct form 1, two stages, state carried across calls; a stage restarts from zero when
    //     its double state is NaN / Inf or beyond float range, i.e. where the float state would have overflowed); per sample:
    //     double NaN -> float NaN, double +-Inf -> same Inf, finite -> within tol * (largest |value| of that call and channel);
    //     a call whose double values go beyond float range must hold at least one non-finite float sample (float overflow = Inf)
    //   - the transcribed upstream loop (RefBiquadStereo) followed by the same restart rule, bit for bit (NaN compared as is-NaN).
    static void RefClearNonFinite(ref BiquadFilterState s)
    {
        if (!float.IsFinite(s.State0) || !float.IsFinite(s.State1) || !float.IsFinite(s.State2) || !float.IsFinite(s.State3))
        {
            s.State0 = 0f; s.State1 = 0f; s.State2 = 0f; s.State3 = 0f;
        }
    }

    // double reference, one channel, two stages, in place on y (double); st[stage][0..3]. Same products and summation order as
    //   the float loop; returns true when any product or partial sum went beyond float range (the float loop gets an Inf there,
    //   and Inf / NaN stays to the end of the call), and that stage then restarts from zero, like a non-finite double state.
    static bool RefBiquadDouble(BiquadFilterParameter2[] parameters, double[][] st, double[] y, int n)
    {
        bool anyOverflow = false;

        for (int stage = 0; stage < 2; stage++)
        {
            Span<float> nu = parameters[stage].Numerator.AsSpan();
            Span<float> de = parameters[stage].Denominator.AsSpan();
            double a0 = nu[0], a1 = nu[1], a2 = nu[2], b1 = de[0], b2 = de[1];
            double s0 = st[stage][0], s1 = st[stage][1], s2 = st[stage][2], s3 = st[stage][3];
            bool overflow = false;

            static bool Over(double v) => double.IsFinite(v) && Math.Abs(v) > float.MaxValue;

            for (int i = 0; i < n; i++)
            {
                double x = y[i];
                double p0 = x * a0, p1 = s0 * a1, p2 = s1 * a2, p3 = s2 * b1, p4 = s3 * b2;
                double q1 = p0 + p1, q2 = q1 + p2, q3 = q2 + p3, o = q3 + p4;
                if (Over(p0) || Over(p1) || Over(p2) || Over(p3) || Over(p4) || Over(q1) || Over(q2) || Over(q3) || Over(o)) overflow = true;
                s1 = s0; s0 = x; s3 = s2; s2 = o;
                y[i] = o;
            }

            if (overflow || !double.IsFinite(s0) || !double.IsFinite(s1) || !double.IsFinite(s2) || !double.IsFinite(s3)) { s0 = s1 = s2 = s3 = 0; }
            st[stage][0] = s0; st[stage][1] = s1; st[stage][2] = s2; st[stage][3] = s3;
            anyOverflow |= overflow;
        }

        return anyOverflow;
    }

    static bool StatesFinite(BiquadFilterState[] s)
    {
        foreach (var x in s)
        {
            if (!float.IsFinite(x.State0) || !float.IsFinite(x.State1) || !float.IsFinite(x.State2) || !float.IsFinite(x.State3)) return false;
        }
        return true;
    }

    static int CountNonFinite(ReadOnlySpan<float> a)
    {
        int c = 0;
        foreach (float v in a) if (!float.IsFinite(v)) c++;
        return c;
    }

    static void TestBiquadNonFinite(Random rnd)
    {
        const int N = 240, Calls = 200, Bad = 50;   // 200 calls x 240 = 48000 samples (1 s at 48 kHz); the bad input lands in call 50

        BiquadFilterParameter2 typ = MakeBiquadParameter(0.5f, 0.25f, 0.125f, 0.3f, -0.1f);    // poles |p| = sqrt(0.1) = 0.316, DC gain 0.875/0.8 = 1.09
        BiquadFilterParameter2 pass = MakeBiquadParameter(1f, 0f, 0f, 0f, 0f);                  // passthrough: zero coefficients turn an Inf state into NaN (Inf * 0)
        // poles r * e^{+-i pi/4}: b1 = 2 r cos(pi/4), b2 = -r^2 (y[n] = ... + b1 y[n-1] + b2 y[n-2])
        static BiquadFilterParameter2 Resonator(double r) => MakeBiquadParameter(1e-3f, 0f, 0f, (float)(2 * r * Math.Cos(Math.PI / 4)), (float)(-r * r));

        var scenarios = new (string name, BiquadFilterParameter2[] p, Func<int, int, int, float> x, double tol, bool expectNonFinite)[]
        {
            // |y| <= sum|h| * 1e30, far below float max: never non-finite
            ("huge 1e30 every 10th call", [typ, pass], (c, ch, i) => c % 10 == 0 ? (rnd.Next(2) == 0 ? 1e30f : -1e30f) : rnd.NextSingle() * 65536f - 32768f, 1e-4, false),
            // ch0 constant +max: DC gain 1.09 > 1 -> |y| > float max -> Inf, then Inf*0.3 + Inf*(-0.1) = NaN; ch1 alternating +-max (gain at Nyquist 0.27)
            ("max 3.4e38 in call 50", [typ, pass], (c, ch, i) => c == Bad ? (ch == 0 ? float.MaxValue : (i % 2 == 0 ? float.MaxValue : -float.MaxValue)) : rnd.NextSingle() * 65536f - 32768f, 1e-4, true),
            // subnormal input: stays subnormal / tiny, never non-finite
            ("subnormal 1e-40", [typ, pass], (c, ch, i) => (rnd.NextSingle() * 2f - 1f) * 1e-40f, 1e-3, false),
            ("NaN at ch0 call 50 sample 17", [typ, pass], (c, ch, i) => c == Bad && ch == 0 && i == 17 ? float.NaN : rnd.NextSingle() * 65536f - 32768f, 1e-4, true),
            ("+Inf at ch1 call 50 sample 3", [typ, pass], (c, ch, i) => c == Bad && ch == 1 && i == 3 ? float.PositiveInfinity : rnd.NextSingle() * 65536f - 32768f, 1e-4, true),
            ("-Inf at ch0 call 50 sample 239", [typ, pass], (c, ch, i) => c == Bad && ch == 0 && i == 239 ? float.NegativeInfinity : rnd.NextSingle() * 65536f - 32768f, 1e-4, true),
            // stable but near the unit circle (r = 0.9999): rings for ~10^4 samples, stays finite
            ("poles r=0.9999", [Resonator(0.9999), pass], (c, ch, i) => rnd.NextSingle() * 65536f - 32768f, 1e-3, false),
            // unstable (r = 1.01): grows 1.01^n, passes float max after ~8900 samples -> Inf / NaN
            ("poles r=1.01 (unstable)", [Resonator(1.01), pass], (c, ch, i) => rnd.NextSingle() * 65536f - 32768f, 1e-3, true),
        };

        foreach (var sc in scenarios)
        {
            BiquadFilterState[] v0 = new BiquadFilterState[2], v1 = new BiquadFilterState[2];   // vector kernel
            BiquadFilterState[] s0 = new BiquadFilterState[2], s1 = new BiquadFilterState[2];   // tree scalar path
            BiquadFilterState[] u0 = new BiquadFilterState[2], u1 = new BiquadFilterState[2];   // upstream loop, no restart (as shipped upstream)
            BiquadFilterState[] r0 = new BiquadFilterState[2], r1 = new BiquadFilterState[2];   // upstream loop + restart rule
            double[][][] d = [[new double[4], new double[4]], [new double[4], new double[4]]];

            int firstBadV = -1, firstBadU = -1, afterV = 0, afterU = 0, afterTotal = 0, nonFiniteCallsV = 0;
            bool vStatesAlwaysFinite = true, sawNonFinite = false;
            double maxRel = 0;
            int failsBefore = fails;

            for (int c = 0; c < Calls; c++)
            {
                float[] in0 = new float[N], in1 = new float[N];
                for (int i = 0; i < N; i++) { in0[i] = sc.x(c, 0, i); in1[i] = sc.x(c, 1, i); }

                float[] vo0 = (float[])in0.Clone(), vo1 = (float[])in1.Clone();
                S2ADspBiquadHelper.ProcessBiquadFilterStereoAdvSimd(sc.p, v0, v1, vo0, vo1, vo0, vo1, N);
                float[] so0 = (float[])in0.Clone(), so1 = (float[])in1.Clone();
                S2ADspBiquadHelper.ProcessBiquadFilterStereoScalar(sc.p, s0, s1, so0, so1, so0, so1, N);
                float[] uo0 = (float[])in0.Clone(), uo1 = (float[])in1.Clone();
                RefBiquadStereo(sc.p, u0, u1, uo0, uo1, uo0, uo1, N);
                float[] ro0 = (float[])in0.Clone(), ro1 = (float[])in1.Clone();
                RefBiquadStereo(sc.p, r0, r1, ro0, ro1, ro0, ro1, N);
                for (int k = 0; k < 2; k++) { RefClearNonFinite(ref r0[k]); RefClearNonFinite(ref r1[k]); }

                string what = $"nonfinite '{sc.name}' call {c}";
                CheckFloatsAnyNan($"{what} vector vs scalar ch0", so0, vo0);
                CheckFloatsAnyNan($"{what} vector vs scalar ch1", so1, vo1);
                CheckFloatsAnyNan($"{what} vector vs upstream+restart ch0", ro0, vo0);
                CheckFloatsAnyNan($"{what} vector vs upstream+restart ch1", ro1, vo1);
                for (int k = 0; k < 2; k++)
                {
                    CheckState($"{what} vector vs scalar ch0 stage{k}", s0[k], v0[k], true);
                    CheckState($"{what} vector vs scalar ch1 stage{k}", s1[k], v1[k], true);
                    CheckState($"{what} vector vs upstream+restart ch0 stage{k}", r0[k], v0[k], true);
                    CheckState($"{what} vector vs upstream+restart ch1 stage{k}", r1[k], v1[k], true);
                }

                cases++;
                if (!StatesFinite(v0) || !StatesFinite(v1) || !StatesFinite(s0) || !StatesFinite(s1))
                {
                    if (vStatesAlwaysFinite) Fail($"{what}: state not finite after the call (restart rule)", c, "finite", $"v=({v0[0].State0:R},{v0[0].State2:R},{v0[1].State2:R}) ch1 ({v1[0].State2:R},{v1[1].State2:R})");
                    vStatesAlwaysFinite = false;
                }

                // double reference
                for (int ch = 0; ch < 2; ch++)
                {
                    float[] inp = ch == 0 ? in0 : in1;
                    float[] got = ch == 0 ? vo0 : vo1;
                    double[] y = new double[N];
                    for (int i = 0; i < N; i++) y[i] = inp[i];
                    bool overflow = RefBiquadDouble(sc.p, d[ch], y, N);

                    int nf = CountNonFinite(got);
                    if (nf > 0) sawNonFinite = true;
                    cases++;
                    if (overflow)
                    {
                        if (nf == 0) Fail($"{what} ch{ch} vs double: double went beyond float range, float call has no Inf/NaN", c, ">=1 non-finite", "0");
                        continue;
                    }

                    double scale = 0;
                    for (int i = 0; i < N; i++) if (double.IsFinite(y[i])) scale = Math.Max(scale, Math.Abs(y[i]));
                    for (int i = 0; i < N; i++)
                    {
                        double w = y[i]; float g = got[i];
                        bool ok = double.IsNaN(w) ? float.IsNaN(g)
                            : double.IsInfinity(w) ? (double)g == w
                            : float.IsFinite(g) && Math.Abs(g - w) <= sc.tol * scale;
                        if (!ok)
                        {
                            Fail($"{what} ch{ch} vs double (tol {sc.tol} x {scale:G3})", i, $"{w:R}", $"{g:R}");
                            break;
                        }
                        if (double.IsFinite(w) && scale > 0) maxRel = Math.Max(maxRel, Math.Abs(g - w) / scale);
                    }
                }

                int nv = CountNonFinite(vo0) + CountNonFinite(vo1), nu2 = CountNonFinite(uo0) + CountNonFinite(uo1);
                if (nv > 0) { nonFiniteCallsV++; if (firstBadV < 0) firstBadV = c; }
                if (nu2 > 0 && firstBadU < 0) firstBadU = c;
                if (firstBadU >= 0 && c > firstBadU) { afterV += nv; afterU += nu2; afterTotal += 2 * N; }
            }

            cases++;
            if (sc.expectNonFinite != sawNonFinite) Fail($"nonfinite '{sc.name}' non-finite output seen", 0, $"{sc.expectNonFinite}", $"{sawNonFinite}");

            Console.WriteLine($"  nonfinite '{sc.name}': 首个非有限输出 call 向量={firstBadV} 上游={firstBadU}；其后各 call 非有限样本 向量 {afterV}/{afterTotal}、上游原循环 {afterU}/{afterTotal}；" +
                $"向量出非有限的 call 数 {nonFiniteCallsV}/{Calls}；上游末态有限={StatesFinite(u0) && StatesFinite(u1)}，向量末态有限={StatesFinite(v0) && StatesFinite(v1)}；对 double 最大相对误差 {maxRel:G3}；红 {fails - failsBefore}");
        }
    }

    // ---- adpcm --------------------------------------------------------------------------------------

    static short RefAdpcmSaturate(int value)
    {
        if (value > short.MaxValue)
        {
            value = short.MaxValue;
        }

        if (value < short.MinValue)
        {
            value = short.MinValue;
        }

        return (short)value;
    }

    static int RefAdpcmRoundUp(int value)
    {
        // FixedPointHelper.RoundUpAndToInt(value, 11), transcribed: half = 1 << 10, then arithmetic shift
        return (int)((value + (1 << 10)) >> 11);
    }

    static short RefAdpcmCoefficient(ReadOnlySpan<short> coefficients, int index)
    {
        return (uint)index < (uint)coefficients.Length ? coefficients[index] : (short)0;
    }

    // upstream AdpcmHelper.Decode, transcribed (scalar only, independent of the kernel under test)
    static int RefAdpcmDecode(Span<short> output, ReadOnlySpan<byte> input, int startSampleOffset, int endSampleOffset, int offset, int count, ReadOnlySpan<short> coefficients, ref AdpcmLoopContext loopContext)
    {
        if (input.IsEmpty || endSampleOffset < startSampleOffset)
        {
            return 0;
        }

        byte predScale = (byte)loopContext.PredScale;
        byte scale = (byte)(predScale & 0xF);
        byte coefficientIndex = (byte)((predScale >> 4) & 0xF);
        short history0 = loopContext.History0;
        short history1 = loopContext.History1;
        short coefficient0 = RefAdpcmCoefficient(coefficients, coefficientIndex * 2);
        short coefficient1 = RefAdpcmCoefficient(coefficients, coefficientIndex * 2 + 1);

        int decodedCount = Math.Min(count, endSampleOffset - startSampleOffset - offset);
        int nibbles = offset % 14 + 16 * (offset / 14) + (offset % 14 != 0 ? 2 : 0); // GetNibblesFromSampleCount(offset), transcribed
        int remaining = decodedCount;
        int outputBufferIndex = 0;
        int inputIndex = 0;
        ReadOnlySpan<byte> targetInput = input[(nibbles / 2)..];

        while (remaining > 0)
        {
            int samplesCount;

            if (((uint)nibbles % 16) == 0)
            {
                predScale = targetInput[inputIndex++];
                scale = (byte)(predScale & 0xF);
                coefficientIndex = (byte)((predScale >> 4) & 0xF);
                coefficient0 = RefAdpcmCoefficient(coefficients, coefficientIndex * 2);
                coefficient1 = RefAdpcmCoefficient(coefficients, coefficientIndex * 2 + 1);
                nibbles += 2;
                samplesCount = Math.Min(remaining, 14);
            }
            else
            {
                samplesCount = 1;
            }

            int scaleFixedPoint = 2048 << scale;

            if (samplesCount < 14)
            {
                for (int i = 0; i < samplesCount; i++)
                {
                    int value = targetInput[inputIndex];
                    int sample;

                    if ((nibbles & 1) != 0)
                    {
                        sample = (value << 28) >> 28;
                        inputIndex++;
                    }
                    else
                    {
                        sample = (value << 24) >> 28;
                    }

                    nibbles++;

                    int prediction = coefficient0 * history0 + coefficient1 * history1;
                    sample = RefAdpcmRoundUp(sample * scaleFixedPoint + prediction);
                    short saturatedSample = RefAdpcmSaturate(sample);

                    history1 = history0;
                    history0 = saturatedSample;

                    output[outputBufferIndex++] = saturatedSample;
                    remaining--;
                }
            }
            else
            {
                for (int i = 0; i < 7; i++)
                {
                    int value = targetInput[inputIndex];

                    int sample0 = (value << 24) >> 28;
                    int sample1 = (value << 28) >> 28;

                    inputIndex++;

                    int prediction0 = coefficient0 * history0 + coefficient1 * history1;
                    sample0 = RefAdpcmRoundUp(sample0 * scaleFixedPoint + prediction0);
                    short saturatedSample0 = RefAdpcmSaturate(sample0);

                    int prediction1 = coefficient0 * saturatedSample0 + coefficient1 * history0;
                    sample1 = RefAdpcmRoundUp(sample1 * scaleFixedPoint + prediction1);
                    short saturatedSample1 = RefAdpcmSaturate(sample1);

                    history1 = saturatedSample0;
                    history0 = saturatedSample1;

                    output[outputBufferIndex++] = saturatedSample0;
                    output[outputBufferIndex++] = saturatedSample1;
                }

                nibbles += 14;
                remaining -= 14;
            }
        }

        loopContext.PredScale = predScale;
        loopContext.History0 = history0;
        loopContext.History1 = history1;

        return decodedCount;
    }

    // one ADPCM stream: every 8th byte is the frame header (predScale: low nibble scale, high nibble coefficient index)
    static byte[] MakeAdpcmStream(Random rnd, int frames, int partialNibbles, out int totalNibbles)
    {
        totalNibbles = 16 * frames + partialNibbles;
        byte[] input = new byte[(totalNibbles + 1) / 2 + 8]; // +8 tail so the last whole frame also passes the 8-byte read guard

        for (int i = 0; i < input.Length; i++)
        {
            input[i] = (byte)rnd.Next(0, 256);
        }

        for (int f = 0; f < frames; f++)
        {
            input[f * 8] = (byte)(rnd.Next(0, 16) | (rnd.Next(0, 16) << 4));
        }

        return input;
    }

    static void CheckLoopContext(string what, AdpcmLoopContext want, AdpcmLoopContext got)
    {
        cases++;
        if (want.PredScale != got.PredScale || want.History0 != got.History0 || want.History1 != got.History1)
        {
            Fail(what, 0, $"predScale={want.PredScale} h0={want.History0} h1={want.History1}", $"predScale={got.PredScale} h0={got.History0} h1={got.History1}");
        }
    }

    static void TestAdpcm(Random rnd)
    {
        int[] offsets = [0, 1, 7, 13, 14, 15, 21, 28, 35, 42];

        // direct frame kernel vs transcribed per-sample chain (covers the nibble unpack and scale multiply alone)
        for (int round = 0; round < 200; round++)
        {
            byte[] frame = new byte[8];
            for (int i = 0; i < 8; i++) frame[i] = (byte)rnd.Next(0, 256);

            byte scale = (byte)rnd.Next(0, 16);
            short coefficient0 = (short)rnd.Next(short.MinValue, short.MaxValue);
            short coefficient1 = (short)rnd.Next(short.MinValue, short.MaxValue);
            int scaleFixedPoint = 2048 << scale;
            short history0 = (short)rnd.Next(short.MinValue, short.MaxValue);
            short history1 = (short)rnd.Next(short.MinValue, short.MaxValue);

            short[] want = new short[14];
            short wh0 = history0, wh1 = history1;
            for (int i = 0; i < 14; i++)
            {
                int value = frame[i / 2];
                int nibble = (i & 1) == 0 ? (value << 24) >> 28 : (value << 28) >> 28;
                int prediction = coefficient0 * wh0 + coefficient1 * wh1;
                short saturated = RefAdpcmSaturate(RefAdpcmRoundUp(nibble * scaleFixedPoint + prediction));
                wh1 = wh0;
                wh0 = saturated;
                want[i] = saturated;
            }

            short[] got = new short[14];
            short gh0 = history0, gh1 = history1;
            AdpcmHelper.DecodeFrameAdvSimd(frame, 0, scaleFixedPoint, coefficient0, coefficient1, ref gh0, ref gh1, got);

            CheckShorts($"adpcm frame r={round} scale={scale}", want, got);
            cases++;
            if (wh0 != gh0 || wh1 != gh1)
            {
                Fail($"adpcm frame r={round} history", 0, $"{wh0},{wh1}", $"{gh0},{gh1}");
            }
        }

        // whole Decode (vector frames under fast-on, pure scalar under fast-off) vs the transcribed reference
        for (int round = 0; round < 240; round++)
        {
            int frames = 1 + round % 5;
            int partialNibbles = round % 3 == 0 ? 0 : 1 + round % 13;
            byte[] input = MakeAdpcmStream(rnd, frames, partialNibbles, out int totalNibbles);

            short[] coefficients = new short[32];
            for (int i = 0; i < coefficients.Length; i++)
            {
                coefficients[i] = round % 4 == 3 ? (short)rnd.Next(-4096, 4096) : (short)rnd.Next(short.MinValue, short.MaxValue);
            }

            var ctxTemplate = new AdpcmLoopContext
            {
                PredScale = (short)rnd.Next(0, 256),
                History0 = (short)rnd.Next(short.MinValue, short.MaxValue),
                History1 = (short)rnd.Next(short.MinValue, short.MaxValue),
            };

            int startSampleOffset = 0;
            int endSampleOffset = totalNibbles - 2; // upper bound; the decoder stops at count anyway
            int offset = offsets[round % offsets.Length];
            int count = endSampleOffset - offset - (round % 5 == 4 ? rnd.Next(0, 30) : 0);

            if (count <= 0)
            {
                continue;
            }

            var ctxWant = ctxTemplate;
            short[] want = new short[count + 16];
            int wantCount = RefAdpcmDecode(want, input, startSampleOffset, endSampleOffset, offset, count, coefficients, ref ctxWant);

            var ctxGot = ctxTemplate;
            short[] got = new short[count + 16];
            int gotCount = AdpcmHelper.Decode(got, input, startSampleOffset, endSampleOffset, offset, count, coefficients, ref ctxGot);

            string what = $"adpcm r={round} frames={frames} partial={partialNibbles} off={offset} count={count}";
            cases++;
            if (wantCount != gotCount)
            {
                Fail($"{what} decodedCount", 0, $"{wantCount}", $"{gotCount}");
                continue;
            }

            CheckShorts(what, want.AsSpan(0, wantCount), got.AsSpan(0, gotCount));
            CheckLoopContext($"{what} loopContext", ctxWant, ctxGot);
        }
    }

    // ---- 6-channel device interleave ----------------------------------------------------------------

    static void RefSaturateInterleave6(Span<short> outputBuffer, ReadOnlySpan<float> c0, ReadOnlySpan<float> c1, ReadOnlySpan<float> c2, ReadOnlySpan<float> c3, ReadOnlySpan<float> c4, ReadOnlySpan<float> c5, int sampleCount)
    {
        for (int j = 0; j < sampleCount; j++)
        {
            outputBuffer[j * 6 + 0] = RefSaturate(c0.Length > j ? c0[j] : 0f);
            outputBuffer[j * 6 + 1] = RefSaturate(c1.Length > j ? c1[j] : 0f);
            outputBuffer[j * 6 + 2] = RefSaturate(c2.Length > j ? c2[j] : 0f);
            outputBuffer[j * 6 + 3] = RefSaturate(c3.Length > j ? c3[j] : 0f);
            outputBuffer[j * 6 + 4] = RefSaturate(c4.Length > j ? c4[j] : 0f);
            outputBuffer[j * 6 + 5] = RefSaturate(c5.Length > j ? c5[j] : 0f);
        }
    }

    static void TestSaturateInterleave6(Random rnd)
    {
        float[] specials =
        [
            0f, float.Epsilon, -float.Epsilon, 0.5f, 1.5f, 2.5f, 3.5f, -0.5f, -1.5f, -2.5f, -3.5f,
            2.4999f, 32766.5f, 32766.9f, 32767f, 32767.4f, 32767.5f, 32767.9f, 32768f, 40000.9f, 3e38f, float.MaxValue,
            -32767.5f, -32768f, -32768.5f, -40000.9f, -3e38f, float.MinValue, -0.4f,
            float.NaN, float.PositiveInfinity, float.NegativeInfinity,
        ];
        int[] counts = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 240, 241, 242, 243, 244, 245, 246, 247];

        for (int round = 0; round < 200; round++)
        {
            int n = counts[round % counts.Length];

            // silent channels: full 5.1 / stereo-upmix-to-5.1 (tail silent) / interior gaps
            int pattern = round % 4;
            float[][] ch = new float[6][];
            for (int c = 0; c < 6; c++)
            {
                bool silent = pattern == 1 && c >= 2;
                silent |= pattern == 3 && (c % 2 == 1);
                ch[c] = silent ? Array.Empty<float>() : new float[n];
            }

            for (int c = 0; c < 6; c++)
            {
                for (int j = 0; j < ch[c].Length; j++)
                {
                    if (round % 3 == 0)
                    {
                        ch[c][j] = specials[(j * 7 + c * 3 + round) % specials.Length];
                    }
                    else if (round % 3 == 1)
                    {
                        ch[c][j] = rnd.Next(-33000, 33000);
                    }
                    else
                    {
                        ch[c][j] = rnd.NextSingle() * 80000f - 40000f;
                    }
                }
            }

            short[] want = new short[Math.Max(n, 1) * 6];
            RefSaturateInterleave6(want, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], n);

            short[] got = new short[want.Length];
            S2ADspMixHelper.SaturateInterleave6AdvSimd(got, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], n);
            CheckShorts($"saturate-interleave6 n={n} r={round} pattern={pattern}", want, got);

            short[] slow = new short[want.Length];
            S2ADspMixHelper.SaturateInterleave6Scalar(slow, ch[0], ch[1], ch[2], ch[3], ch[4], ch[5], 0, n);
            CheckShorts($"saturate-interleave6 n={n} r={round} pattern={pattern} vs scalar", want, slow);
        }
    }

    // ---- optional kernel timing (not part of the green/red verdict) --------------------------------

    static float _benchFraction; // lambda 传 ref 需要字段

    static long TimeIterations(Action action, int iterations)
    {
        var sw = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++) action();
        return sw.ElapsedTicks * 1000 / iterations;
    }

    static void Bench()
    {
        const int N = 240; // TargetSampleCount per 5 ms render cycle
        var rnd = new Random(20261111);

        float ratio = 1.3777778f; // 48000 -> 384000/277.71-ish upscale shape, exercises the fast path
        float[] parD = ResamplerHelper.GetDefaultParameter(ratio).ToArray();
        float[] parH = ResamplerHelper.GetHighParameter(ratio).ToArray();
        short[] input = FillShorts(rnd, ((int)ratio + 2) * N + 64, 1);
        float[] outA = new float[N], outB = new float[N];
        float[] chA = new float[N], chB = new float[N], chC = new float[N];
        for (int i = 0; i < N; i++)
        {
            chA[i] = rnd.NextSingle() - 0.5f;
            chB[i] = rnd.NextSingle() - 0.5f;
            chC[i] = rnd.NextSingle() - 0.5f;
        }

        float[] coefficients = [0.70710677f, 0.70710677f, 0.70710677f, 0.70710677f];
        short[] shorts = new short[N * 2];
        short[] shorts6 = new short[N * 6];

        Console.WriteLine($"bench (JIT, N={N}): ns/call median of 7 x 5000");

        void Row(string name, Action fast, Action slow)
        {
            fast(); slow();
            long[] a = new long[7], b = new long[7];
            for (int i = 0; i < 7; i++)
            {
                a[i] = TimeIterations(fast, 5000);
                b[i] = TimeIterations(slow, 5000);
            }

            Array.Sort(a); Array.Sort(b);
            Console.WriteLine($"  {name}: vector {a[3]} ns vs scalar {b[3]} ns -> {b[3] / (double)a[3]:F2}x");
        }

        Row("resample default (4 tap)", () => { _benchFraction = 0.5f; ResamplerHelper.ResampleDefaultQualityAdvSimd(outA, input, ratio, ref _benchFraction, N, parD); },
            () => RefResampleDefault(input, parD, ratio, 0.5f, N, outB, out _));
        Row("resample high (8 tap)", () => { _benchFraction = 0.5f; ResamplerHelper.ResampleHighQualityAdvSimd(outA, input, ratio, ref _benchFraction, N, parH); },
            () => RefResampleHigh(input, parH, ratio, 0.5f, N, outB, out _));
        Row("downmix 5.1->stereo", () => S2ADspMixHelper.DownMixSurroundToStereoAdvSimd(outA, outB, chA, chB, chC, chC, chA, chB, coefficients, N),
            () => S2ADspMixHelper.DownMixSurroundToStereoScalar(outA, outB, chA, chB, chC, chC, chA, chB, coefficients, 0, N));
        Row("mix ramp", () => S2ADspMixHelper.MixRampAdvSimd(outA, chA, 0.25f, 0.001f, N),
            () => S2ADspMixHelper.MixRampScalar(outA, chA, 0.25f, 0.001f, 0, N));
        Row("volume ramp", () => S2ADspMixHelper.VolumeRampAdvSimd(outA, chA, 0.75f, -0.001f, N),
            () => S2ADspMixHelper.VolumeRampScalar(outA, chA, 0.75f, -0.001f, 0, N));
        Row("device sink saturate+interleave", () => S2ADspMixHelper.SaturateInterleaveStereoAdvSimd(shorts, chA, chB, N),
            () => S2ADspMixHelper.SaturateInterleaveStereoScalar(shorts, chA, chB, 0, N));
        Row("device sink interleave 6ch", () => S2ADspMixHelper.SaturateInterleave6AdvSimd(shorts6, chA, chB, chC, chC, chA, chB, N),
            () => S2ADspMixHelper.SaturateInterleave6Scalar(shorts6, chA, chB, chC, chC, chA, chB, 0, N));

        BiquadFilterParameter2[] bqParams =
        [
            MakeBiquadParameter(0.9f, -0.4f, 0.2f, 0.3f, -0.1f),
            MakeBiquadParameter(0.7f, 0.25f, -0.125f, -0.2f, 0.05f),
        ];
        BiquadFilterState[] bqStates0 = new BiquadFilterState[2], bqStates1 = new BiquadFilterState[2];
        BiquadFilterState[] bqStates0b = new BiquadFilterState[2], bqStates1b = new BiquadFilterState[2];
        foreach (var st in new[] { bqStates0, bqStates1, bqStates0b, bqStates1b })
        {
            for (int i = 0; i < 2; i++)
            {
                st[i].State0 = 0.1f;
                st[i].State1 = -0.2f;
                st[i].State2 = 0.3f;
                st[i].State3 = -0.4f;
            }
        }
        Row("biquad stereo packed (2ch x 2 stage)",
            () => S2ADspBiquadHelper.ProcessBiquadFilterStereoAdvSimd(bqParams, bqStates0, bqStates1, outA, outB, chA, chB, N),
            () => RefBiquadStereo(bqParams, bqStates0b, bqStates1b, chA, chB, outB, outA, N));

        byte[] adpcmIn = MakeAdpcmStream(rnd, 18, 0, out int adpcmNibbles);
        short[] adpcmCoeffs = new short[32];
        for (int i = 0; i < 32; i++) adpcmCoeffs[i] = (short)((i * 2731) % 8192 - 4096);
        short[] adpcmOut = new short[N + 16];
        Row("adpcm decode 240 samples",
            () => { var ctx = new AdpcmLoopContext(); AdpcmHelper.Decode(adpcmOut, adpcmIn, 0, adpcmNibbles - 2, 0, N, adpcmCoeffs, ref ctx); },
            () => { var ctx = new AdpcmLoopContext(); RefAdpcmDecode(adpcmOut, adpcmIn, 0, adpcmNibbles - 2, 0, N, adpcmCoeffs, ref ctx); });
    }

    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--bench")
        {
            Bench();
            return 0;
        }

        Console.WriteLine($"vector path: {(AdvSimd.IsSupported ? "on" : "off (no AdvSimd: nothing to compare)")}");
        if (!AdvSimd.IsSupported) return 0;

        var rnd = new Random(20261111);

        TestResample(rnd, high: false);
        TestResample(rnd, high: true);
        TestDownMix(rnd);
        TestRamp(rnd);
        TestSaturateInterleave(rnd);
        TestBiquadStereo(rnd);
        TestBiquadNonFinite(rnd);
        TestAdpcm(rnd);
        TestSaturateInterleave6(rnd);
        TestWiring(rnd);

        Console.WriteLine(fails == 0 ? $"audio_dsp_simd: all green ({cases} comparisons, S2ADspFast.On={S2ADspFast.On})" : $"audio_dsp_simd: {fails} red of {cases} (S2ADspFast.On={S2ADspFast.On})");
        return fails == 0 ? 0 : 1;
    }
}
