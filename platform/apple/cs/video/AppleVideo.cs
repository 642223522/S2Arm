using Ryujinx.Graphics.Nvdec;
using Ryujinx.Graphics.Video;
using System.Runtime.InteropServices;

namespace S2A.Apple.Video
{
    // 苹果装配登记视频解码器（平台 adapter P1，#1069）：Host.Boot 之前调一次
    public static class AppleVideo
    {
        // 宿主链没链真 libvpx（services/vpx 真身回 1；S2A_VPX 探测到本机可走系统 VP9、不链真身时链的是全失败的空垫片
        //   services/vpx/stub.c，回 0——nvn2_codec.c 按同一导出回，直连线同一条口径）。垫片下 VP8 没有任何后端
        //   （VideoToolbox 不解 VP8、托管也没有 VP8 解码器）：工厂回 null 落 UnavailableVp8Decoder（如实报红不出假画面）；
        //   VP9 落 VideoToolbox 系统后端 → 托管的既有回退链，原生段跳过
        [DllImport("s2a_native")] private static extern int s2a_vpx_linked();

        public static void Register()
        {
            S2AVideoDecoders.H264 = static () => new Ryujinx.Graphics.Nvdec.Apple.VideoToolboxH264Decoder();
            S2AVideoDecoders.Vp8 = static () => s2a_vpx_linked() != 0 ? new Ryujinx.Graphics.Nvdec.Vpx.VpxVp8Decoder() : null;   // 共用 libvpx 封装（安卓的 AndroidVp8Decoder 也包它）；VideoToolbox 不解 VP8，垫片下无后端
            // VP9：macOS 上 VideoToolbox 硬解优先（探针＝实建一次 64x64 会话，#348 的判据；注册 API 要 macOS 11 / iOS 26.2，
            // iOS 18 部署目标没有——iOS 与探针不过的 Mac 一律 libvpx），与安卓 MediaCodec 后端（#232）同一回退链：
            //   后端探针过 → 会话 / 单作业表示不了时按 Vp9NativePath 的既有机器逐级回退（libvpx 原生段 → 托管解码器）。
            //   链了真身时系统后端缺省关（S2A_NVDEC_VP9_VT=1 才开，缺省 libvpx 原生）；垫片下系统后端默认开（VideoToolboxVp9Backend.
            //   TryCreate 同一判据），原生段跳过——VP9 落系统 → 托管。S2A_NVDEC_VP9=managed 关掉整条原生路径。
            S2AVideoDecoders.Vp9 = static () =>
                (IVp9NativeBackend)Ryujinx.Graphics.Nvdec.Apple.VideoToolboxVp9Backend.TryCreate() ??
                (s2a_vpx_linked() != 0 ? new Ryujinx.Graphics.Nvdec.Vpx.VpxVp9Backend() : null);
            S2AVideoDecoders.Vp9DefaultMode = "native";   // 与安卓同一缺省（#247）：不登记时恒走托管解码器，P4G 类 VP9 过场吃满整核
        }
    }
}
