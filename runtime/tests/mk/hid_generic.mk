# native-test-hid_generic：Mac 通用 HID 手柄的映射 / 让位 / 首次按键占位（macos/hid_generic.h，纯 C 头、不引系统头），所以不走 runtime/src/<名>.c 的通用规则。
NATIVE_TEST_OWN += hid_generic
.PHONY: native-test-hid_generic
native-test-hid_generic:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Imacos -o $(BUILD)/tests/t_hid_generic runtime/tests/t_hid_generic.c
	$(BUILD)/tests/t_hid_generic
TEST_TARGETS += native-test-hid_generic
