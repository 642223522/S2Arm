# native-test-sign_state：签名证书进游戏状态（ios/sign_state.m 每款签名状态 / 挑现用证书；runtime/src/selfsign.c 导入时登记 certs.tsv）。要 openssl，只 Mac
NATIVE_TEST_OWN += sign_state
ifeq ($(S2A_UNAME),Darwin)
.PHONY: native-test-sign_state
native-test-sign_state:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Iruntime/src -DS2A_UNIT_TEST -o $(BUILD)/tests/t_sign_state runtime/tests/t_sign_state.m ios/sign_state.m runtime/src/selfsign.c \
	  -framework Foundation -framework Security -framework CoreFoundation $(S2A_HOST_WEAK)
	timeout 60 $(BUILD)/tests/t_sign_state
TEST_TARGETS += native-test-sign_state
endif
