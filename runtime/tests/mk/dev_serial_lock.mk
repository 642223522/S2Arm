# native-test-dev_serial_lock：开发机 Mac 局串行锁（runtime/src/dev_serial_lock.h，host_main.c 起局前调用）
NATIVE_TEST_OWN += dev_serial_lock
.PHONY: native-test-dev_serial_lock
native-test-dev_serial_lock:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_dev_serial_lock runtime/tests/t_dev_serial_lock.c
	$(BUILD)/tests/t_dev_serial_lock
TEST_TARGETS += native-test-dev_serial_lock
