# native-test-xstack_leaf：叶子桩（xstack.c + entry.S xs_leaf_entry）单测；entry.S 别的入口引用的运行时符号由测试给占位；平台层用真的 plat_apple.c
NATIVE_TEST_OWN += xstack_leaf
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-xstack_leaf
native-test-xstack_leaf:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_xstack_leaf runtime/tests/t_xstack_leaf.c runtime/src/xstack.c runtime/src/entry.S platform/apple/plat_apple.c -Wl,-undefined,dynamic_lookup
	$(BUILD)/tests/t_xstack_leaf
TEST_TARGETS += native-test-xstack_leaf
endif
