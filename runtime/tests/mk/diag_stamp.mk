# native-test-diag_stamp：S2A_DIAG_STAMP 重叠开窗（runtime/src/diag_brk.c，#f1ad1e）；diag_brk 只在 Mac 宿主有实现，本单测只在 macOS 编
NATIVE_TEST_OWN += diag_stamp
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-diag_stamp
native-test-diag_stamp:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -DS2A_UNIT_TEST -o $(BUILD)/tests/t_diag_stamp runtime/tests/t_diag_stamp.c
	$(BUILD)/tests/t_diag_stamp
TEST_TARGETS += native-test-diag_stamp
endif
