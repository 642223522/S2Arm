# native-test-program_resign：起局按款重签（ios/program_resign.m，0.6.0 通用壳手机侧）。要 codesign / cc / openssl，只 Mac
NATIVE_TEST_OWN += program_resign
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-program_resign
native-test-program_resign:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Iruntime/src -DS2A_UNIT_TEST -o $(BUILD)/tests/t_program_resign runtime/tests/t_program_resign.m ios/program_resign.m ios/prov_expiry.m runtime/src/selfsign.c \
	  -framework Foundation -framework Security -framework CoreFoundation $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_program_resign
TEST_TARGETS += native-test-program_resign
endif
