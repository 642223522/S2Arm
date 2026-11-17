# native-test-nvn_tex_mis_placeholder：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tex_mis_placeholder
ifeq ($(S2A_UNAME),Darwin)
# 维度不符时绑的是开局占位贴图不标红
$(BUILD)/tests/t_nvn_tex_mis_placeholder: graphics/nvn/tests/t_nvn_tex_mis_placeholder.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tex_mis_placeholder.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tex_mis_placeholder
native-test-nvn_tex_mis_placeholder: $(BUILD)/tests/t_nvn_tex_mis_placeholder
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_tex_mis_placeholder
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_tex_mis_placeholder
TEST_TARGETS += native-test-nvn_tex_mis_placeholder
endif
