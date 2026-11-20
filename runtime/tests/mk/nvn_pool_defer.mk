# native-test-nvn_pool_defer：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pool_defer
ifeq ($(S2A_UNAME),Darwin)
# 池注销按回放顺序：释放后再回放完一次提交才注销（nvn_mtl.m pool_reap）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_pool_defer: graphics/nvn/tests/t_nvn_pool_defer.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn2_cmd.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pool_defer.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pool_defer
native-test-nvn_pool_defer: $(BUILD)/tests/t_nvn_pool_defer
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_pool_defer
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_pool_defer
TEST_TARGETS += native-test-nvn_pool_defer
endif
