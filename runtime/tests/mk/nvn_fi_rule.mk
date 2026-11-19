# 出图补帧逐帧判定（只给 30 帧档或更低档、跑满的帧补；60 帧档不补）：graphics/nvn/tests/t_nvn_fi_rule.c，纯 C、不碰 Metal
NATIVE_TEST_OWN += nvn_fi_rule
$(BUILD)/tests/t_nvn_fi_rule: graphics/nvn/tests/t_nvn_fi_rule.c graphics/nvn/gfx/nvn/nvn_fi_rule.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -o $@ graphics/nvn/tests/t_nvn_fi_rule.c
.PHONY: native-test-nvn_fi_rule
native-test-nvn_fi_rule: $(BUILD)/tests/t_nvn_fi_rule
	$(BUILD)/tests/t_nvn_fi_rule
TEST_TARGETS += native-test-nvn_fi_rule
