# native-test-nvn_addr_adhoc：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_addr_adhoc
ifeq ($(S2A_UNAME),Darwin)
# 地址兜底：池外的客体内存登记成池再用（nvn_mtl.m addr_adhoc）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_addr_adhoc: graphics/nvn/tests/t_nvn_addr_adhoc.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn2_cmd.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_addr_adhoc.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_addr_adhoc
native-test-nvn_addr_adhoc: $(BUILD)/tests/t_nvn_addr_adhoc
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_addr_adhoc
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_addr_adhoc
TEST_TARGETS += native-test-nvn_addr_adhoc
endif
