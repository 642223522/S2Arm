# 上屏拷贝只在画进画布那次套补丁画幅（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_present_aspect.m；#1169）
NATIVE_TEST_OWN += present_aspect
ifeq ($(S2A_UNAME),Darwin)
PRESENT_ASPECT_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
PRESENT_ASPECT_BINARY ?= $(BUILD)/tests/t_nvn_present_aspect
$(PRESENT_ASPECT_BINARY): graphics/nvn/tests/t_present_aspect.m $(PRESENT_ASPECT_SOURCE) $(NVN_MTL_DEPS) $(dir $(PRESENT_ASPECT_SOURCE))nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DPRESENT_ASPECT_SOURCE='"$(abspath $(PRESENT_ASPECT_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_present_aspect.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-present_aspect
native-test-present_aspect: $(PRESENT_ASPECT_BINARY)
	$(PRESENT_ASPECT_BINARY)
TEST_TARGETS += native-test-present_aspect
endif
