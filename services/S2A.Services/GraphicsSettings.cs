using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using System;

namespace S2A.Services
{
    public static class GraphicsSettings
    {
        // 在创建 Switch / 游戏纹理之前调，窗口必须是套 ThreadedRenderer 之前的真实后端：
        // 上游 ThreadedWindow 的画面设置 setter 为空，不能经它设置后处理。
        public static void Apply(IRenderer renderer)
        {
            string scale = Environment.GetEnvironmentVariable("S2A_RES_SCALE") ?? "1";
            float resolutionScale = scale switch
            {
                "0.5" => 0.5f,
                "0.75" => 0.75f,
                "1" => 1f,
                "1.5" => 1.5f,
                "2" => 2f,
                _ => throw new ArgumentOutOfRangeException("S2A_RES_SCALE", scale, "可选 0.5、0.75、1、1.5、2"),
            };
            string aa = Environment.GetEnvironmentVariable("S2A_ANTI_ALIASING") ?? "None";
            AntiAliasing antiAliasing = aa switch
            {
                "None" => AntiAliasing.None,
                "SmaaMedium" => AntiAliasing.SmaaMedium,
                "SmaaHigh" => AntiAliasing.SmaaHigh,
                _ => throw new ArgumentOutOfRangeException("S2A_ANTI_ALIASING", aa, "可选 None、SmaaMedium、SmaaHigh（不带 FXAA）"),
            };
            string filter = Environment.GetEnvironmentVariable("S2A_SCALING_FILTER") ?? "Bilinear";
            ScalingFilter scalingFilter = filter switch
            {
                "Bilinear" => ScalingFilter.Bilinear,
                "Nearest" => ScalingFilter.Nearest,
                // MetalFX：直连上屏层自己读这个值做 MetalFX 空间放大（graphics/nvn nvn_present_fx.inc）；这里是 Ryujinx 渲染器的设置，通用模式没有 MetalFX，按双线性
                "MetalFX" => ScalingFilter.Bilinear,
                // Fsr（AMD FSR 1）：直连上屏层自己做（graphics/nvn nvn_present_fsr.inc）；通用模式的 FSR 没实现（graphics/metal gal_present.m 对它报「按双线性」），这里直接按双线性
                "Fsr" => ScalingFilter.Bilinear,
                _ => throw new ArgumentOutOfRangeException("S2A_SCALING_FILTER", filter, "可选 Bilinear、Nearest、MetalFX、Fsr"),
            };

            GraphicsConfig.ResScale = resolutionScale;
            renderer.Window.SetAntiAliasing(antiAliasing);
            renderer.Window.SetScalingFilter(scalingFilter);
            Console.Error.WriteLine($"[S2A 画面] 渲染倍率 {scale}x，抗锯齿 {antiAliasing}，缩放滤镜 {scalingFilter}{(filter == "MetalFX" ? "（设的是 MetalFX：直连上屏用 MetalFX，通用模式按双线性）" : filter == "Fsr" ? "（设的是 Fsr：直连上屏用 FSR 1，通用模式按双线性）" : "")}");
        }
    }
}
