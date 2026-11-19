# native-test-nvn_hybrid：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_hybrid
ifeq ($(S2A_UNAME),Darwin)
# 混合管线：首遇不能跳的绘制用拉取管线先画（nvn_hybrid.inc）；选择、布局块、真画像素与精确管线一致
$(BUILD)/tests/t_nvn_hybrid: graphics/nvn/tests/t_nvn_hybrid.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_hybrid.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_hybrid
native-test-nvn_hybrid: $(BUILD)/tests/t_nvn_hybrid
	$(BUILD)/tests/t_nvn_hybrid
TEST_TARGETS += native-test-nvn_hybrid
endif
