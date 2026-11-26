# native-test-nvn2_codec：Switch 2 直连档的视频解码接管 nvn2_codec.c——图像池、VP9（libvpx，services/vpx 同一份库）/ AV1（VideoToolbox；没有 AV1 硬件解码的机器跳过并说明；
#   dav1d 软解逐帧 MD5 对 ffmpeg 参考、强制软解走整条路径）
#   解码器协议、H.264（VideoToolbox，起始码 / 长度前缀两种输入）、同步点事件、av1C、NVN2 原生图像 → 线性纹理；纯 C + 替身，不需要游戏
# dav1d 垫片是弱符号：S2A_DAV1D_EFF=0（本机探测有 AV1 硬解，tools/av1hw.sh）时这条单测不链 dav1d 照常跑——dav1d 软解小节按符号缺位跳过，
#   VideoToolbox / H.264 / VP9 / av1C 小节照测；只有 dav1d 垫片的小节（垫片声明不带 weak）才是硬依赖。
# libvpx 照宿主同一口径：S2A_VPX_EFF=0（本机可走系统 VP9，tools/vp9hw.sh）时链全失败的空垫片（services/vpx/build_stub.sh）——
#   VP9 系统小节照跑（vp9_system_enabled 见 s2a_vpx_linked()=0 默认开），对拍（要真 libvpx 当参考）按 s2a_vpx_linked() 跳过
NATIVE_TEST_OWN += nvn2_codec
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-nvn2_codec
native-test-nvn2_codec:
	@mkdir -p $(BUILD)/tests
	vpxlib= && \
	if [ "$(S2A_VPX_EFF)" != 0 ]; then vpxlib=$$(bash services/vpx/build.sh osx-arm64 | tail -1); else vpxlib=$$(bash services/vpx/build_stub.sh osx-arm64 | tail -1); fi && [ -f "$$vpxlib" ] && \
	dav1d= && \
	if [ "$(S2A_DAV1D_EFF)" != 0 ]; then dav1d=$$(bash services/dav1d/build.sh osx-arm64 | tail -1) && [ -f "$$dav1d" ]; fi && \
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/host -o $(BUILD)/tests/t_nvn2_codec \
	  graphics/nvn/tests/t_nvn2_codec.c graphics/nvn/gfx/nvn/nvn2_codec.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c "$$vpxlib" $${dav1d:+"$$dav1d"} $(call S2A_WEAK_U,nvntest) \
	  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation
	timeout 60 $(BUILD)/tests/t_nvn2_codec
TEST_TARGETS += native-test-nvn2_codec
endif
