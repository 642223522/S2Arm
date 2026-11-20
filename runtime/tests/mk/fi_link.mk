# 补帧与显示链互斥（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_fi_link.m；#ee56e7 / #1155）
NATIVE_TEST_OWN += fi_link
ifeq ($(S2A_UNAME),Darwin)
FI_LINK_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
FI_LINK_BINARY ?= $(BUILD)/tests/t_nvn_fi_link
$(FI_LINK_BINARY): graphics/nvn/tests/t_fi_link.m $(FI_LINK_SOURCE) $(NVN_MTL_DEPS) $(dir $(FI_LINK_SOURCE))nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DFI_LINK_SOURCE='"$(abspath $(FI_LINK_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_fi_link.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-fi_link
native-test-fi_link: $(FI_LINK_BINARY)
	$(FI_LINK_BINARY)
TEST_TARGETS += native-test-fi_link
endif
