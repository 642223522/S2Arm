# native-test-mac_rumble：Mac 手柄震动（macos/front_mac.m）的强度换算与播放器回退接线；换算在 ios/haptic_retry.h（纯 C 头）
NATIVE_TEST_OWN += mac_rumble
.PHONY: native-test-mac_rumble
native-test-mac_rumble:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -o $(BUILD)/tests/t_mac_rumble runtime/tests/t_mac_rumble.c
	$(BUILD)/tests/t_mac_rumble macos/front_mac.m
TEST_TARGETS += native-test-mac_rumble
