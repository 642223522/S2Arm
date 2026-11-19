# 游戏中途改深度模式后，旧程序按新约定重解（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_depth_reresolve.m）
NATIVE_TEST_OWN += depth_reresolve
ifeq ($(S2A_UNAME),Darwin)
DEPTH_RERESOLVE_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
DEPTH_RERESOLVE_BINARY ?= $(BUILD)/tests/t_nvn_depth_reresolve
$(DEPTH_RERESOLVE_BINARY): graphics/nvn/tests/t_depth_reresolve.m $(DEPTH_RERESOLVE_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DDEPTH_RERESOLVE_SOURCE='"$(abspath $(DEPTH_RERESOLVE_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_depth_reresolve.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-depth_reresolve
native-test-depth_reresolve: $(DEPTH_RERESOLVE_BINARY)
	$(DEPTH_RERESOLVE_BINARY)
TEST_TARGETS += native-test-depth_reresolve
endif
