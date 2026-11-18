# native-test-nvn_bg_purge：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_bg_purge
ifeq ($(S2A_UNAME),Darwin)
# 切后台瘦身只标能重建的打包贴图（D-CZCW）
$(BUILD)/tests/t_nvn_bg_purge: graphics/nvn/tests/t_nvn_bg_purge.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_bg_purge.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_bg_purge
native-test-nvn_bg_purge: $(BUILD)/tests/t_nvn_bg_purge
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_bg_purge
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_bg_purge
TEST_TARGETS += native-test-nvn_bg_purge
endif
