# native-test-nvn_sparse_page：Metal 稀疏贴图的页假设（NVN 稀疏页 = 块线性连续 64 KB、单页合成描述去混排 = 整级子区域），纯 C
NATIVE_TEST_OWN += nvn_sparse_page
.PHONY: native-test-nvn_sparse_page
native-test-nvn_sparse_page:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/tex -o $(BUILD)/tests/t_nvn_sparse_page runtime/tests/t_nvn_sparse_page.c graphics/nvn/gfx/nvn/nvn_tex.c graphics/nvn/gfx/tex/nvn_deswizzle.c
	$(BUILD)/tests/t_nvn_sparse_page
TEST_TARGETS += native-test-nvn_sparse_page
