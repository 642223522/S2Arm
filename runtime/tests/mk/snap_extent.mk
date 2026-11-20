# native-test-snap_extent：即时存档后备文件按块查（runtime/src/snapfile.h），新方法不漏旧方法找到的非零页；负对照一页不标必须不通
NATIVE_TEST_OWN += snap_extent
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-snap_extent
native-test-snap_extent:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Wall -Wextra -Werror -o $(BUILD)/tests/t_snap_extent runtime/tests/t_snap_extent.c
	$(BUILD)/tests/t_snap_extent
TEST_TARGETS += native-test-snap_extent
endif
