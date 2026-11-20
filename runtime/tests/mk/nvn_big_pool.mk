# native-test-nvn_big_pool：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_big_pool
ifeq ($(S2A_UNAME),Darwin)
# 大内存池按块用到才包（马车世界缺口 ②，上游参考实现（MIT）big_pool）
$(BUILD)/tests/t_nvn_big_pool: graphics/nvn/tests/t_nvn_big_pool.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_big_pool.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_big_pool
native-test-nvn_big_pool: $(BUILD)/tests/t_nvn_big_pool
	$(BUILD)/tests/t_nvn_big_pool
TEST_TARGETS += native-test-nvn_big_pool
endif
