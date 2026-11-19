// libvpx 的空垫片（与 s2a_vp8.c / s2a_vp9.c 同一套导出，外加 s2a_vpx_linked）：S2A_VPX 探测到本机可走系统 VP9
//   （tools/vp9hw.sh）、宿主 / iOS 不链 libvpx 时链这一份（services/build.mk），垫住 C# 侧 DirectPInvoke 的静态强引用
//   （VpxVp9Backend / VpxVp8Decoder，S2A.Aot.csproj DirectPInvoke s2a_vpx——直接放行未定义符号会在 dyld 启动时报
//   symbol not found，实测）。所有打开一律回 NULL / 解码一律回失败：VP9 走系统路线（nvn2_codec.c / AppleVideo.cs
//   见 s2a_vpx_linked() = 0 默认开 VideoToolbox，逐级回退到托管）；VP8 无任何系统 / 托管替代（VideoToolbox 不解 VP8，
//   AppleVideo.cs 的注），调用方拿到失败如实报红，不出假画面。
// 签名与真身逐一同形；s2a_vp9_nvdec 的 io / pic 用指针占位（真类型 vpx/s2a_vp9_nvdec.h 在 libvpx 补丁里，stub 不依赖
//   libvpx 源码——参数全是指针，ABI 同形）。
#include <stddef.h>
#include <stdint.h>

int s2a_vpx_linked(void) { return 0; }   // 真身（libs2a_vpx.a，s2a_vp9.c）回 1：C 侧（nvn2_codec.c）与 C# 侧（AppleVideo.cs）都问它决定路线
void *s2a_vp9_open(int threads) { (void)threads; return NULL; }
int s2a_vp9_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info)
{ (void)h; (void)data; (void)len; (void)planes; (void)strides; (void)info; return -1; }
void s2a_vp9_close(void *h) { (void)h; }
int s2a_vp9_nvdec(void *h, const uint8_t *frame, uint32_t size, const void *io, void *pic, const char **error)
{
    (void)h; (void)frame; (void)size; (void)io; (void)pic;
    if (error) *error = "宿主没链 libvpx（S2A_VPX 探测到本机可走系统 VP9，tools/vp9hw.sh）";
    return -1;
}
void *s2a_vp8_open(void) { return NULL; }
int s2a_vp8_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *wh)
{ (void)h; (void)data; (void)len; (void)planes; (void)strides; (void)wh; return -1; }
void s2a_vp8_close(void *h) { (void)h; }
