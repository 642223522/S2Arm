using System;

namespace Ryujinx.Audio.Backends.Apple   // 平台例外：Apple 后端平台实现的命名空间（#189 后续，5.1 虚拟环绕）
{
    // S2Arm（#189 后续，5.1 虚拟环绕）：用户显式选择的输出设备类型。不做自动检测——transport 只说明接口——
    //   3.5mm 分不出耳机 / aux 音箱、USB 可能是耳机 / 耳麦 / 音箱、蓝牙 A2DP 同样分不出；AUSM 的 .auto 在
    //   5.1 路径上也测不出（内置 / USB / DisplayPort 三路由全部退化为 ExternalSpeakers 普通平移，见
    //   docs/坑记录.md），显式 Headphones / BuiltInSpeakers 才虚拟化。语义由用户选择定（S2A_AUDIO_DEVICE）：
    //     builtin     内置扬声器；VS 开关 S2A_AUDIO_VS_SPEAKERS（缺省关）
    //     headphones  耳机；VS 开关 S2A_AUDIO_VS_HEADPHONES（缺省关）
    //     external    外接 / TV 扬声器；永不虚拟环绕——实际设备 ≥6 声道直通、<6 声道普通下混
    //   未设 / 不认识 → Auto：按设备真实声道自动判（同 main 的 #577 判据），不套 VS——保住 5.1 设备玩家
    //   的直通（评审 11-16：缺省不能把接 HDMI / DisplayPort 5.1 的玩家降成立体声）
    internal enum AppleAudioDeviceType
    {
        BuiltInSpeakers = 0,
        Headphones = 1,
        ExternalSpeakers = 2,
        Auto = 3,
    }

    internal static class AppleAudioDeviceTypeSelector
    {
        public const AppleAudioDeviceType DefaultDeviceType = AppleAudioDeviceType.Auto;

        public static AppleAudioDeviceType FromEnvironment()
        {
            string value = Environment.GetEnvironmentVariable("S2A_AUDIO_DEVICE");

            if (string.IsNullOrWhiteSpace(value))
            {
                return DefaultDeviceType;
            }

            switch (value.Trim().ToLowerInvariant())
            {
                case "auto":
                case "automatic":
                    return AppleAudioDeviceType.Auto;
                case "builtin":
                case "builtinspeakers":
                case "speakers":
                    return AppleAudioDeviceType.BuiltInSpeakers;
                case "headphones":
                case "headphone":
                    return AppleAudioDeviceType.Headphones;
                case "external":
                case "externalspeakers":
                case "tv":
                    return AppleAudioDeviceType.ExternalSpeakers;
                default:
                    Console.Error.WriteLine($"[声] 【红】S2A_AUDIO_DEVICE=「{value}」不认识（可用 builtin / headphones / external）：按 {DeviceName(DefaultDeviceType)}");
                    return DefaultDeviceType;
            }
        }

        public static string DeviceName(AppleAudioDeviceType type)
        {
            return type switch
            {
                AppleAudioDeviceType.Auto => "未显式选择（按设备自动判）",
                AppleAudioDeviceType.BuiltInSpeakers => "内置扬声器（builtin）",
                AppleAudioDeviceType.Headphones => "耳机（headphones）",
                _ => "外接扬声器（external）",
            };
        }

        // 对应设备类型的虚拟环绕开关：builtin 看 S2A_AUDIO_VS_SPEAKERS、headphones 看 S2A_AUDIO_VS_HEADPHONES
        //   （两个开关按类型分别保存，切换类型时各自恢复，不互相覆盖）；只在玩家显式选了 builtin / headphones
        //   时才生效（评审 11-16），Auto / external 永远关
        public static bool VirtualSurround(AppleAudioDeviceType type)
        {
            return type switch
            {
                AppleAudioDeviceType.BuiltInSpeakers => Environment.GetEnvironmentVariable("S2A_AUDIO_VS_SPEAKERS") == "1",
                AppleAudioDeviceType.Headphones => Environment.GetEnvironmentVariable("S2A_AUDIO_VS_HEADPHONES") == "1",
                _ => false,
            };
        }
    }
}
