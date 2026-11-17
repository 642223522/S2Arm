# native-test-nvn_stex：放置式稀疏贴图块管理（graphics/nvn/gfx/nvn/nvn_stex.inc）在本机 GPU 上：映射 / 上传、按物理内存共享堆页、GPU 写的稀疏贴图、丢失计数（要 Metal 4，macOS 26+）
NATIVE_TEST_OWN += nvn_stex
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_stex: runtime/tests/t_nvn_stex.m graphics/nvn/gfx/nvn/nvn_stex.inc graphics/nvn/gfx/nvn/nvn_tex.c graphics/nvn/gfx/nvn/nvn_tex.h graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/tex/nvn_deswizzle.h graphics/nvn/gfx/nvn/nvn_hmap.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-missing-field-initializers -Wno-unguarded-availability-new -Wno-unguarded-availability -o $@ runtime/tests/t_nvn_stex.m graphics/nvn/gfx/nvn/nvn_tex.c graphics/nvn/gfx/tex/nvn_deswizzle.c -framework Metal -framework Foundation
.PHONY: native-test-nvn_stex
native-test-nvn_stex: $(BUILD)/tests/t_nvn_stex
	$(BUILD)/tests/t_nvn_stex
TEST_TARGETS += native-test-nvn_stex
endif
