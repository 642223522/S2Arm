# native-test-nvn_copy_fmt：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_copy_fmt
ifeq ($(S2A_UNAME),Darwin)
# 贴图→贴图拷贝补齐（深度 / 整数 / 伸出目标 / 2D 拷进 3D / 格式换算）：完整 bootstrap、录制、Metal 3/4 回放与公开纹理读回。
$(BUILD)/tests/t_nvn_copy_fmt: graphics/nvn/tests/t_nvn_copy_fmt.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_copy_fmt.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_copy_fmt
native-test-nvn_copy_fmt: $(BUILD)/tests/t_nvn_copy_fmt
	$(BUILD)/tests/t_nvn_copy_fmt
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_copy_fmt
TEST_TARGETS += native-test-nvn_copy_fmt
endif
