// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Graphics.Nvdec.Apple;   // 平台例外：本用例只验苹果 VideoToolbox 解码器换参考帧数的时机（platform/apple/cs/video，#529）；服务层单测只在 macOS 上跑

namespace S2A.Services.Tests
{
    // #529：VideoToolbox 会话中途换 SPS 的 max_num_ref_frames（片头第 3 帧 3 → 4），原会话判不可接受、新会话收非 IDR 帧报 -12909。
    //   原先「ue 编码等长就当场切」（3、4 都是 5 bit），M4 / macOS 27.2 上照样被拒。期望（手写，按语义）：非 IDR 一律不切（等 IDR），
    //   IDR 切，首次定值（当前 0）直接定
    public static partial class Program
    {
        [SvcCase]
        private static void VtRefFramesSwitchWaitsForIdr()
        {
            Check("参考帧数 3 → 4、非 IDR：不当场切，等 IDR", false, VideoToolboxH264Decoder.RefFramesSwitchNow(false, 3));
            Check("参考帧数 3 → 9、非 IDR：不当场切，等 IDR", false, VideoToolboxH264Decoder.RefFramesSwitchNow(false, 3));
            Check("IDR 帧：切", true, VideoToolboxH264Decoder.RefFramesSwitchNow(true, 3));
            Check("首次定值（当前 0）：直接定", true, VideoToolboxH264Decoder.RefFramesSwitchNow(false, 0));
        }
    }
}
