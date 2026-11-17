# native-test-nvn_pool_chunk：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pool_chunk
ifeq ($(S2A_UNAME),Darwin)
# 超过单个 Metal buffer 上限的内存池按重叠块登记（#1196）
$(BUILD)/tests/t_nvn_pool_chunk: graphics/nvn/tests/t_nvn_pool_chunk.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pool_chunk.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pool_chunk
native-test-nvn_pool_chunk: $(BUILD)/tests/t_nvn_pool_chunk
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_pool_chunk
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_pool_chunk
TEST_TARGETS += native-test-nvn_pool_chunk
endif
