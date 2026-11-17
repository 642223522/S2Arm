using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using Ryujinx.Audio.Renderer.Parameter.Effect;
using Ryujinx.Common.Memory;
using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Audio.Renderer.Dsp
{
    public static class BiquadFilterHelper
    {
        private const int FixedPointPrecisionForParameter = 14;

        public static BiquadFilterParameter1 ToBiquadFilterParameter1(BiquadFilterParameter2 parameter)
        {
            BiquadFilterParameter1 result = new()
            {
                Enable = parameter.Enable, Numerator = new Array3<short>(), Denominator = new Array2<short>()
            };

            Span<short> resultNumeratorSpan = result.Numerator.AsSpan();
            Span<short> resultDenominatorSpan = result.Denominator.AsSpan();
            
            Span<float> parameterNumeratorSpan = parameter.Numerator.AsSpan();
            Span<float> parameterDenominatorSpan = parameter.Denominator.AsSpan();
            
            
            resultNumeratorSpan[0] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[0], FixedPointPrecisionForParameter);
            resultNumeratorSpan[1] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[1], FixedPointPrecisionForParameter);
            resultNumeratorSpan[2] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[2], FixedPointPrecisionForParameter);
            
            resultDenominatorSpan[0] = (short)FixedPointHelper.ToFixed(parameterDenominatorSpan[0], FixedPointPrecisionForParameter);
            resultDenominatorSpan[1] = (short)FixedPointHelper.ToFixed(parameterDenominatorSpan[1], FixedPointPrecisionForParameter);
            
            return result;
        }
        
        public static BiquadFilterParameter2 ToBiquadFilterParameter2(BiquadFilterParameter1 parameter)
        {
            BiquadFilterParameter2 result = new()
            {
                Enable = parameter.Enable, Numerator = new Array3<float>(), Denominator = new Array2<float>()
            };

            Span<float> resultNumeratorSpan = result.Numerator.AsSpan();
            Span<float> resultDenominatorSpan = result.Denominator.AsSpan();
            
            Span<short> parameterNumeratorSpan = parameter.Numerator.AsSpan();
            Span<short> parameterDenominatorSpan = parameter.Denominator.AsSpan();
            
            
            resultNumeratorSpan[0] = FixedPointHelper.ToFloat(parameterNumeratorSpan[0], FixedPointPrecisionForParameter);
            resultNumeratorSpan[1] = FixedPointHelper.ToFloat(parameterNumeratorSpan[1], FixedPointPrecisionForParameter);
            resultNumeratorSpan[2] = FixedPointHelper.ToFloat(parameterNumeratorSpan[2], FixedPointPrecisionForParameter);
            
            resultDenominatorSpan[0] = FixedPointHelper.ToFloat(parameterDenominatorSpan[0], FixedPointPrecisionForParameter);
            resultDenominatorSpan[1] = FixedPointHelper.ToFloat(parameterDenominatorSpan[1], FixedPointPrecisionForParameter);
            
            return result;
        }
        
        public static BiquadFilterEffectParameter1 ToBiquadFilterEffectParameter1(BiquadFilterEffectParameter2 parameter)
        {
            BiquadFilterEffectParameter1 result = new()
            {
                Input = parameter.Input, 
                Output = parameter.Output, 
                Numerator = new Array3<short>(), 
                Denominator = new Array2<short>(),
                ChannelCount = parameter.ChannelCount,
                Status = parameter.Status,
            };

            Span<short> resultNumeratorSpan = result.Numerator.AsSpan();
            Span<short> resultDenominatorSpan = result.Denominator.AsSpan();
            
            Span<float> parameterNumeratorSpan = parameter.Numerator.AsSpan();
            Span<float> parameterDenominatorSpan = parameter.Denominator.AsSpan();
            
            
            resultNumeratorSpan[0] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[0], FixedPointPrecisionForParameter);
            resultNumeratorSpan[1] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[1], FixedPointPrecisionForParameter);
            resultNumeratorSpan[2] = (short)FixedPointHelper.ToFixed(parameterNumeratorSpan[2], FixedPointPrecisionForParameter);
            
            resultDenominatorSpan[0] = (short)FixedPointHelper.ToFixed(parameterDenominatorSpan[0], FixedPointPrecisionForParameter);
            resultDenominatorSpan[1] = (short)FixedPointHelper.ToFixed(parameterDenominatorSpan[1], FixedPointPrecisionForParameter);
            
            return result;
        }
        
        public static BiquadFilterEffectParameter2 ToBiquadFilterEffectParameter2(BiquadFilterEffectParameter1 parameter)
        {
            BiquadFilterEffectParameter2 result = new()
            {
                Input = parameter.Input, 
                Output = parameter.Output, 
                Numerator = new Array3<float>(), 
                Denominator = new Array2<float>(),
                ChannelCount = parameter.ChannelCount,
                Status = parameter.Status,
            };

            Span<float> resultNumeratorSpan = result.Numerator.AsSpan();
            Span<float> resultDenominatorSpan = result.Denominator.AsSpan();
            
            Span<short> parameterNumeratorSpan = parameter.Numerator.AsSpan();
            Span<short> parameterDenominatorSpan = parameter.Denominator.AsSpan();
            
            
            resultNumeratorSpan[0] = FixedPointHelper.ToFloat(parameterNumeratorSpan[0], FixedPointPrecisionForParameter);
            resultNumeratorSpan[1] = FixedPointHelper.ToFloat(parameterNumeratorSpan[1], FixedPointPrecisionForParameter);
            resultNumeratorSpan[2] = FixedPointHelper.ToFloat(parameterNumeratorSpan[2], FixedPointPrecisionForParameter);
            
            resultDenominatorSpan[0] = FixedPointHelper.ToFloat(parameterDenominatorSpan[0], FixedPointPrecisionForParameter);
            resultDenominatorSpan[1] = FixedPointHelper.ToFloat(parameterDenominatorSpan[1], FixedPointPrecisionForParameter);
            
            return result;
        }

        /// <summary>
        /// Apply a single biquad filter.
        /// </summary>
        /// <remarks>This is implemented with a direct form 2.</remarks>
        /// <param name="parameter">The biquad filter parameter</param>
        /// <param name="state">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void ProcessBiquadFilter(
            ref BiquadFilterParameter2 parameter,
            ref BiquadFilterState state,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount)
        {
            Span<float> numeratorSpan = parameter.Numerator.AsSpan();
            Span<float> denominatorSpan = parameter.Denominator.AsSpan();
            
            float a0 = numeratorSpan[0];
            float a1 = numeratorSpan[1];
            float a2 = numeratorSpan[2];

            float b1 = denominatorSpan[0];
            float b2 = denominatorSpan[1];

            // S2Arm: 快路径同上（状态放局部变量）；运算与顺序同原循环
            if (S2ADspFast.On)
            {
                float s0 = state.State0, s1 = state.State1;

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = inputBuffer[i];
                    float output = input * a0 + s0;

                    s0 = input * a1 + output * b1 + s1;
                    s1 = input * a2 + output * b2;

                    outputBuffer[i] = output;
                }

                state.State0 = s0; state.State1 = s1;
                S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)：状态出现 NaN / Inf 就清零，见 S2ADspBiquadHelper.ClearIfNotFinite
                return;
            }

            for (int i = 0; i < sampleCount; i++)
            {
                float input = inputBuffer[i];
                float output = input * a0 + state.State0;

                state.State0 = input * a1 + output * b1 + state.State1;
                state.State1 = input * a2 + output * b2;

                outputBuffer[i] = output;
            }

            S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)
        }

        /// <summary>
        /// Apply a single biquad filter and mix the result into the output buffer.
        /// </summary>
        /// <remarks>This is implemented with a direct form 1.</remarks>
        /// <param name="parameter">The biquad filter parameter</param>
        /// <param name="state">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        /// <param name="volume">Mix volume</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void ProcessBiquadFilterAndMix(
            ref BiquadFilterParameter2 parameter,
            ref BiquadFilterState state,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount,
            float volume)
        {
            Span<float> numeratorSpan = parameter.Numerator.AsSpan();
            Span<float> denominatorSpan = parameter.Denominator.AsSpan();
            
            float a0 = numeratorSpan[0];
            float a1 = numeratorSpan[1];
            float a2 = numeratorSpan[2];

            float b1 = denominatorSpan[0];
            float b2 = denominatorSpan[1];

            // S2Arm: 快路径（S2A_AUDIO_DSP_FAST=1）同 ProcessBiquadFilter：状态放局部变量逐样本推进、末尾写回，
            //   运算与顺序同下方原循环，输出一致
            if (S2ADspFast.On)
            {
                float s0 = state.State0, s1 = state.State1, s2 = state.State2, s3 = state.State3;

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = inputBuffer[i];
                    float output = input * a0 + s0 * a1 + s1 * a2 + s2 * b1 + s3 * b2;

                    s1 = s0;
                    s0 = input;
                    s3 = s2;
                    s2 = output;

                    outputBuffer[i] += FloatingPointHelper.MultiplyRoundUp(output, volume);
                }

                state.State0 = s0; state.State1 = s1; state.State2 = s2; state.State3 = s3;
                S2ADspBiquadHelper.ClearIfNotFinite(ref state);
                return;
            }

            for (int i = 0; i < sampleCount; i++)
            {
                float input = inputBuffer[i];
                float output = input * a0 + state.State0 * a1 + state.State1 * a2 + state.State2 * b1 + state.State3 * b2;

                state.State1 = state.State0;
                state.State0 = input;
                state.State3 = state.State2;
                state.State2 = output;

                outputBuffer[i] += FloatingPointHelper.MultiplyRoundUp(output, volume);
            }

            S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)：状态出现 NaN / Inf 就清零，见 S2ADspBiquadHelper.ClearIfNotFinite
        }

        /// <summary>
        /// Apply a single biquad filter and mix the result into the output buffer with volume ramp.
        /// </summary>
        /// <remarks>This is implemented with a direct form 1.</remarks>
        /// <param name="parameter">The biquad filter parameter</param>
        /// <param name="state">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        /// <param name="volume">Initial mix volume</param>
        /// <param name="ramp">Volume increment step</param>
        /// <returns>Last filtered sample value</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static float ProcessBiquadFilterAndMixRamp(
            ref BiquadFilterParameter2 parameter,
            ref BiquadFilterState state,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount,
            float volume,
            float ramp)
        {
            Span<float> numeratorSpan = parameter.Numerator.AsSpan();
            Span<float> denominatorSpan = parameter.Denominator.AsSpan();
            
            float a0 = numeratorSpan[0];
            float a1 = numeratorSpan[1];
            float a2 = numeratorSpan[2];

            float b1 = denominatorSpan[0];
            float b2 = denominatorSpan[1];

            float mixState = 0f;

            // S2Arm: 快路径（S2A_AUDIO_DSP_FAST=1）同上，状态放局部变量逐样本推进、末尾写回
            if (S2ADspFast.On)
            {
                float s0 = state.State0, s1 = state.State1, s2 = state.State2, s3 = state.State3;

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = inputBuffer[i];
                    float output = input * a0 + s0 * a1 + s1 * a2 + s2 * b1 + s3 * b2;

                    s1 = s0;
                    s0 = input;
                    s3 = s2;
                    s2 = output;

                    mixState = FloatingPointHelper.MultiplyRoundUp(output, volume);

                    outputBuffer[i] += mixState;
                    volume += ramp;
                }

                state.State0 = s0; state.State1 = s1; state.State2 = s2; state.State3 = s3;
                S2ADspBiquadHelper.ClearIfNotFinite(ref state);
                return mixState;
            }

            for (int i = 0; i < sampleCount; i++)
            {
                float input = inputBuffer[i];
                float output = input * a0 + state.State0 * a1 + state.State1 * a2 + state.State2 * b1 + state.State3 * b2;

                state.State1 = state.State0;
                state.State0 = input;
                state.State3 = state.State2;
                state.State2 = output;

                mixState = FloatingPointHelper.MultiplyRoundUp(output, volume);

                outputBuffer[i] += mixState;
                volume += ramp;
            }

            S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)

            return mixState;
        }

        /// <summary>
        /// Apply multiple biquad filter.
        /// </summary>
        /// <remarks>This is implemented with a direct form 1.</remarks>
        /// <param name="parameters">The biquad filter parameter</param>
        /// <param name="states">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void ProcessBiquadFilter(
            ReadOnlySpan<BiquadFilterParameter2> parameters,
            Span<BiquadFilterState> states,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount)
        {
            for (int stageIndex = 0; stageIndex < parameters.Length; stageIndex++)
            {
                BiquadFilterParameter2 parameter = parameters[stageIndex];

                ref BiquadFilterState state = ref states[stageIndex];
                
                Span<float> numeratorSpan = parameter.Numerator.AsSpan();
                Span<float> denominatorSpan = parameter.Denominator.AsSpan();

                float a0 = numeratorSpan[0];
                float a1 = numeratorSpan[1];
                float a2 = numeratorSpan[2];

                float b1 = denominatorSpan[0];
                float b2 = denominatorSpan[1];

                // S2Arm: 快路径（S2A_AUDIO_DSP_FAST=1）把状态放进局部变量逐样本推进、末尾写回；运算与顺序同下方原循环，输出一致。
                //   原循环每个样本经 ref 读写 4 个状态字段（输出缓冲可能与状态别名，编译器不能放寄存器）
                if (S2ADspFast.On)
                {
                    float s0 = state.State0, s1 = state.State1, s2 = state.State2, s3 = state.State3;
                    ReadOnlySpan<float> src = stageIndex != 0 ? outputBuffer : inputBuffer;

                    for (int i = 0; i < sampleCount; i++)
                    {
                        float input = src[i];
                        float output = input * a0 + s0 * a1 + s1 * a2 + s2 * b1 + s3 * b2;

                        s1 = s0;
                        s0 = input;
                        s3 = s2;
                        s2 = output;

                        outputBuffer[i] = output;
                    }

                    state.State0 = s0; state.State1 = s1; state.State2 = s2; state.State3 = s3;
                    S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)：状态出现 NaN / Inf 就清零，见 S2ADspBiquadHelper.ClearIfNotFinite
                    continue;
                }

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = stageIndex != 0 ? outputBuffer[i] : inputBuffer[i];
                    float output = input * a0 + state.State0 * a1 + state.State1 * a2 + state.State2 * b1 + state.State3 * b2;

                    state.State1 = state.State0;
                    state.State0 = input;
                    state.State3 = state.State2;
                    state.State2 = output;

                    outputBuffer[i] = output;
                }

                S2ADspBiquadHelper.ClearIfNotFinite(ref state); // S2Arm (#1182)
            }
        }

        /// <summary>
        /// Apply double biquad filter and mix the result into the output buffer.
        /// </summary>
        /// <remarks>This is implemented with a direct form 1.</remarks>
        /// <param name="parameters">The biquad filter parameter</param>
        /// <param name="states">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        /// <param name="volume">Mix volume</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void ProcessDoubleBiquadFilterAndMix(
            ref BiquadFilterParameter2 parameter0,
            ref BiquadFilterParameter2 parameter1,
            ref BiquadFilterState state0,
            ref BiquadFilterState state1,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount,
            float volume)
        {
            Span<float> numerator0Span = parameter0.Numerator.AsSpan();
            Span<float> numerator1Span = parameter1.Numerator.AsSpan();
            Span<float> denominator0Span = parameter0.Denominator.AsSpan();
            Span<float> denominator1Span = parameter1.Denominator.AsSpan();
            
            
            float a00 = numerator0Span[0];
            float a10 = numerator0Span[1];
            float a20 = numerator0Span[2];

            float b10 = denominator0Span[0];
            float b20 = denominator0Span[1];

            float a01 = numerator1Span[0];
            float a11 = numerator1Span[1];
            float a21 = numerator1Span[2];

            float b11 = denominator1Span[0];
            float b21 = denominator1Span[1];

            // S2Arm: 快路径（S2A_AUDIO_DSP_FAST=1）同上：两级状态都放局部变量逐样本推进、末尾写回
            if (S2ADspFast.On)
            {
                float s00 = state0.State0, s01 = state0.State1, s02 = state0.State2, s03 = state0.State3;
                float s10 = state1.State0, s11 = state1.State1, s12 = state1.State2, s13 = state1.State3;

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = inputBuffer[i];
                    float output = input * a00 + s00 * a10 + s01 * a20 + s02 * b10 + s03 * b20;

                    s01 = s00;
                    s00 = input;
                    s03 = s02;
                    s02 = output;

                    input = output;
                    output = input * a01 + s10 * a11 + s11 * a21 + s12 * b11 + s13 * b21;

                    s11 = s10;
                    s10 = input;
                    s13 = s12;
                    s12 = output;

                    outputBuffer[i] += FloatingPointHelper.MultiplyRoundUp(output, volume);
                }

                state0.State0 = s00; state0.State1 = s01; state0.State2 = s02; state0.State3 = s03;
                state1.State0 = s10; state1.State1 = s11; state1.State2 = s12; state1.State3 = s13;
                S2ADspBiquadHelper.ClearIfNotFinite(ref state0);
                S2ADspBiquadHelper.ClearIfNotFinite(ref state1);
                return;
            }

            for (int i = 0; i < sampleCount; i++)
            {
                float input = inputBuffer[i];
                float output = input * a00 + state0.State0 * a10 + state0.State1 * a20 + state0.State2 * b10 + state0.State3 * b20;

                state0.State1 = state0.State0;
                state0.State0 = input;
                state0.State3 = state0.State2;
                state0.State2 = output;

                input = output;
                output = input * a01 + state1.State0 * a11 + state1.State1 * a21 + state1.State2 * b11 + state1.State3 * b21;

                state1.State1 = state1.State0;
                state1.State0 = input;
                state1.State3 = state1.State2;
                state1.State2 = output;

                outputBuffer[i] += FloatingPointHelper.MultiplyRoundUp(output, volume);
            }

            S2ADspBiquadHelper.ClearIfNotFinite(ref state0); // S2Arm (#1182)
            S2ADspBiquadHelper.ClearIfNotFinite(ref state1);
        }

        /// <summary>
        /// Apply double biquad filter and mix the result into the output buffer with volume ramp.
        /// </summary>
        /// <remarks>This is implemented with a direct form 1.</remarks>
        /// <param name="parameters">The biquad filter parameter</param>
        /// <param name="states">The biquad filter state</param>
        /// <param name="outputBuffer">The output buffer to write the result</param>
        /// <param name="inputBuffer">The input buffer to read the samples from</param>
        /// <param name="sampleCount">The count of samples to process</param>
        /// <param name="volume">Initial mix volume</param>
        /// <param name="ramp">Volume increment step</param>
        /// <returns>Last filtered sample value</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static float ProcessDoubleBiquadFilterAndMixRamp(
            ref BiquadFilterParameter2 parameter0,
            ref BiquadFilterParameter2 parameter1,
            ref BiquadFilterState state0,
            ref BiquadFilterState state1,
            Span<float> outputBuffer,
            ReadOnlySpan<float> inputBuffer,
            uint sampleCount,
            float volume,
            float ramp)
        {
            Span<float> numerator0Span = parameter0.Numerator.AsSpan();
            Span<float> numerator1Span = parameter1.Numerator.AsSpan();
            Span<float> denominator0Span = parameter0.Denominator.AsSpan();
            Span<float> denominator1Span = parameter1.Denominator.AsSpan();
            
            float a00 = numerator0Span[0];
            float a10 = numerator0Span[1];
            float a20 = numerator0Span[2];

            float b10 = denominator0Span[0];
            float b20 = denominator0Span[1];

            float a01 = numerator1Span[0];
            float a11 = numerator1Span[1];
            float a21 = numerator1Span[2];

            float b11 = denominator1Span[0];
            float b21 = denominator1Span[1];

            float mixState = 0f;

            // S2Arm: 快路径（S2A_AUDIO_DSP_FAST=1）同上：两级状态都放局部变量逐样本推进、末尾写回
            if (S2ADspFast.On)
            {
                float s00 = state0.State0, s01 = state0.State1, s02 = state0.State2, s03 = state0.State3;
                float s10 = state1.State0, s11 = state1.State1, s12 = state1.State2, s13 = state1.State3;

                for (int i = 0; i < sampleCount; i++)
                {
                    float input = inputBuffer[i];
                    float output = input * a00 + s00 * a10 + s01 * a20 + s02 * b10 + s03 * b20;

                    s01 = s00;
                    s00 = input;
                    s03 = s02;
                    s02 = output;

                    input = output;
                    output = input * a01 + s10 * a11 + s11 * a21 + s12 * b11 + s13 * b21;

                    s11 = s10;
                    s10 = input;
                    s13 = s12;
                    s12 = output;

                    mixState = FloatingPointHelper.MultiplyRoundUp(output, volume);

                    outputBuffer[i] += mixState;
                    volume += ramp;
                }

                state0.State0 = s00; state0.State1 = s01; state0.State2 = s02; state0.State3 = s03;
                state1.State0 = s10; state1.State1 = s11; state1.State2 = s12; state1.State3 = s13;
                S2ADspBiquadHelper.ClearIfNotFinite(ref state0);
                S2ADspBiquadHelper.ClearIfNotFinite(ref state1);
                return mixState;
            }

            for (int i = 0; i < sampleCount; i++)
            {
                float input = inputBuffer[i];
                float output = input * a00 + state0.State0 * a10 + state0.State1 * a20 + state0.State2 * b10 + state0.State3 * b20;

                state0.State1 = state0.State0;
                state0.State0 = input;
                state0.State3 = state0.State2;
                state0.State2 = output;

                input = output;
                output = input * a01 + state1.State0 * a11 + state1.State1 * a21 + state1.State2 * b11 + state1.State3 * b21;

                state1.State1 = state1.State0;
                state1.State0 = input;
                state1.State3 = state1.State2;
                state1.State2 = output;

                mixState = FloatingPointHelper.MultiplyRoundUp(output, volume);

                outputBuffer[i] += mixState;
                volume += ramp;
            }

            S2ADspBiquadHelper.ClearIfNotFinite(ref state0); // S2Arm (#1182)
            S2ADspBiquadHelper.ClearIfNotFinite(ref state1);

            return mixState;
        }
    }
}
