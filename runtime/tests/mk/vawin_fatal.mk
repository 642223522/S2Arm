# native-test-vawin_fatal：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_fatal
ifeq ($(S2A_UNAME),Darwin)
# 窗口没占到时的 FATAL 文字按本款跨度与空洞上界说（vawin.c s2a_window_fatal_msg）
.PHONY: native-test-vawin_fatal
native-test-vawin_fatal: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_fatal runtime/tests/t_vawin_fatal.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_fatal
TEST_TARGETS += native-test-vawin_fatal
endif
