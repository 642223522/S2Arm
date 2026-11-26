# native-test-snap_layout：即时存档宿主结构完整布局的提取、存读与跨版本按字段转换（runtime/src/snapfmt.h；期望取编译器 offsetof / sizeof）
NATIVE_TEST_OWN += snap_layout
.PHONY: native-test-snap_layout
native-test-snap_layout:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Wall -Wextra -Werror -Wno-unused-function -o $(BUILD)/tests/t_snap_layout runtime/tests/t_snap_layout.c
	$(BUILD)/tests/t_snap_layout
TEST_TARGETS += native-test-snap_layout
