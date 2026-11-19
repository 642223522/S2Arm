# native-test-sgrade_line：iPhone 设置页 S 级状态句（ios/sgrade_line.m），纯 Foundation 宿主直跑；文案取 ios/l10n/zh-Hans.lproj 的真表
NATIVE_TEST_OWN += sgrade_line
.PHONY: native-test-sgrade_line
native-test-sgrade_line:
	@mkdir -p $(BUILD)/tests/sgrade_line
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -framework Foundation -o $(BUILD)/tests/sgrade_line/t_sgrade_line runtime/tests/t_sgrade_line.m ios/sgrade_line.m
	@rm -rf $(BUILD)/tests/sgrade_line/zh-Hans.lproj && cp -R ios/l10n/zh-Hans.lproj $(BUILD)/tests/sgrade_line/
	$(BUILD)/tests/sgrade_line/t_sgrade_line
TEST_TARGETS += native-test-sgrade_line
