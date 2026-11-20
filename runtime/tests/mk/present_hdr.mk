# native-test-present_hdr：PR3b present_mode 数学闭环 GPU 对拍（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_present_hdr.m；
#   评审稿 v3 §2.4 / §4 PR3b：期望值 CPU 双精度复算 ±1 LSB、off 不变量对改前 trivial 采样着色器逐字节比对；前端替身按 t_nvn2 直调先例注入合成快照）。
#   第二遍进程跑 S2A_HDR_SDR_GAMMA=0 的分段 sRGB 口径（Q13 参数留可调：开关读一次缓存，进程内不换——所以分进程起第二遍）
NATIVE_TEST_OWN += present_hdr
ifeq ($(S2A_UNAME),Darwin)
PRESENT_HDR_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
PRESENT_HDR_BINARY ?= $(BUILD)/tests/t_nvn_present_hdr   # 目标名以 t_nvn_ 开头：吃到 runtime/build.mk 生成头（gen/gal_tess_msl.h、AA 表）的 -I（同 present_aspect.mk 先例）
$(PRESENT_HDR_BINARY): graphics/nvn/tests/t_present_hdr.m $(PRESENT_HDR_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DT_PRESENT_HDR_SOURCE='"$(abspath $(PRESENT_HDR_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_present_hdr.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-present_hdr
native-test-present_hdr: $(PRESENT_HDR_BINARY)
	$(PRESENT_HDR_BINARY)
	S2A_HDR_SDR_GAMMA=0 T_PRESENT_HDR_GAMMA0=1 $(PRESENT_HDR_BINARY)
TEST_TARGETS += native-test-present_hdr
endif
