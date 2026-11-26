# native-test-nvn_layer_clear：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_layer_clear
ifeq ($(S2A_UNAME),Darwin)
# 清除覆盖绑定视图的全部层（01002FC00412C000 点光源阴影立方体，移植自 nxnative ffdf67de）；反证：DM_NVN_LAYER_CLEAR=0 → ① ③ ④ ⑤ 红
$(BUILD)/tests/t_nvn_layer_clear: graphics/nvn/tests/t_nvn_layer_clear.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_layer_clear.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_layer_clear
native-test-nvn_layer_clear: $(BUILD)/tests/t_nvn_layer_clear
	$(BUILD)/tests/t_nvn_layer_clear
TEST_TARGETS += native-test-nvn_layer_clear
endif
