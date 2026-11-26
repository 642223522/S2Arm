# native-test-nvn_bc_rt_nobc：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_bc_rt_nobc
ifeq ($(S2A_UNAME),Darwin)
# 无 BC 时 BC 贴图当块写：块影子画完用解码核解回（nvn_mtl.m bcdec_attach）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_bc_rt_nobc: graphics/nvn/tests/t_nvn_bc_rt_nobc.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn2_cmd.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_bc_rt_nobc.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_bc_rt_nobc
native-test-nvn_bc_rt_nobc: $(BUILD)/tests/t_nvn_bc_rt_nobc
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_bc_rt_nobc
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_bc_rt_nobc
TEST_TARGETS += native-test-nvn_bc_rt_nobc
endif
