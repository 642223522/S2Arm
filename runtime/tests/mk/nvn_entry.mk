# native-test-nvn_entry：NVN 汇编入口在游戏 sp 不对齐时不崩（graphics/nvn/gfx/nvn/nvn_entry.S；槽表 / 实现表 / 回调由单测打桩，不链直连库）
NATIVE_TEST_OWN += nvn_entry
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-nvn_entry
native-test-nvn_entry:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_nvn_entry graphics/nvn/tests/t_nvn_entry.c graphics/nvn/gfx/nvn/nvn_entry.S
	$(BUILD)/tests/t_nvn_entry
TEST_TARGETS += native-test-nvn_entry
endif
