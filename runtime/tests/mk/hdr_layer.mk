# native-test-hdr_layer：PR4 层状态机与层配置单测（graphics/nvn/tests/t_hdr_layer.c；评审稿 v3 §2.3 / §4 PR4）——
#   tick 滞回 / 排空纯逻辑（合成时钟）+ 排空计数喂入断言 + 层配置解析（S0/S1）+ nvn2.c 存储侧开机预挂与喂入；
#   纯 C，不需要 GPU / 游戏。三态流：基线（无 PR4 实现）上 hdr_layer_config / nvn2_hdr_preattach 不存在 → 链接红。
NATIVE_TEST_OWN += hdr_layer
.PHONY: native-test-hdr_layer
native-test-hdr_layer:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -o $(BUILD)/tests/t_hdr_layer graphics/nvn/tests/t_hdr_layer.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c
	$(BUILD)/tests/t_hdr_layer
TEST_TARGETS += native-test-hdr_layer
