# native-test-snapsw：即时存档开关两态（runtime/src/snapsw.c：苹果端缺省开、S2A_SNAP_MODE=0 关；恢复局另算）
NATIVE_TEST_OWN += snapsw
.PHONY: native-test-snapsw
native-test-snapsw:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Wall -Wextra -Werror -o $(BUILD)/tests/t_snapsw runtime/tests/t_snapsw.c
	$(BUILD)/tests/t_snapsw
TEST_TARGETS += native-test-snapsw
