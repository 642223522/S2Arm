# native-test-haptic_retry：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 被测逻辑是 ios/haptic_retry.h（纯 C 头，无 CoreHaptics / GameController 依赖），所以不走 runtime/src/<名>.c 的通用规则。
NATIVE_TEST_OWN += haptic_retry
.PHONY: native-test-haptic_retry
native-test-haptic_retry:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -o $(BUILD)/tests/t_haptic_retry runtime/tests/t_haptic_retry.c
	$(BUILD)/tests/t_haptic_retry ios/controller.m
TEST_TARGETS += native-test-haptic_retry

# native-test-ea_rumble：GameSir G8+ MFi 有线马达的配件判定与组包（ios/ea_rumble.h 纯 C 部分，#462）
NATIVE_TEST_OWN += ea_rumble
.PHONY: native-test-ea_rumble
native-test-ea_rumble:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -o $(BUILD)/tests/t_ea_rumble runtime/tests/t_ea_rumble.c
	$(BUILD)/tests/t_ea_rumble
TEST_TARGETS += native-test-ea_rumble

# native-test-haptic_safe：CoreHaptics 调用防抛包装（ios/haptic_safe.h，D-APX8 等：引擎被系统停掉后对播放器调用抛 ObjC 异常整局 abort）
ifeq ($(S2A_UNAME),Darwin)
NATIVE_TEST_OWN += haptic_safe
.PHONY: native-test-haptic_safe
native-test-haptic_safe:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -Iios -o $(BUILD)/tests/t_haptic_safe runtime/tests/t_haptic_safe.m -framework Foundation -framework CoreHaptics
	$(BUILD)/tests/t_haptic_safe macos/front_mac.m ios/controller.m ios/slot_feedback.m ios/phone_motion.m
TEST_TARGETS += native-test-haptic_safe
endif
