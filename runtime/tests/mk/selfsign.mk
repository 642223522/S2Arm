# native-test-selfsign：手机端自签的权限槽与 codesign 逐字节对照（要 codesign / cc / openssl，只 Mac）
NATIVE_TEST_OWN += selfsign
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-selfsign
native-test-selfsign:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_selfsign runtime/tests/t_selfsign.c runtime/src/selfsign.c -framework Security -framework CoreFoundation $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_selfsign
TEST_TARGETS += native-test-selfsign
endif
