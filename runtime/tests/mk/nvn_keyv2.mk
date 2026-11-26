# native-test-nvn_keyv2：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_keyv2
ifeq ($(S2A_UNAME),Darwin)
# Switch 1 着色器键第 2 代与宿主旧包兜底（nvn_key.h、hle_nvn.c keys_hash、nvn_mtl.m nvn_be_shader_key_pick）
$(BUILD)/tests/t_nvn_keyv2: graphics/nvn/tests/t_nvn_keyv2.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_keyv2.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_keyv2
native-test-nvn_keyv2: $(BUILD)/tests/t_nvn_keyv2
	$(BUILD)/tests/t_nvn_keyv2
TEST_TARGETS += native-test-nvn_keyv2
endif
