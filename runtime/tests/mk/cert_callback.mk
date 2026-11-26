# native-test-cert_callback：SideStore「把签名证书交给别的 App」往返地址的拼法与解析（ios/cert_callback.m，只用 Foundation，Mac 上跑）
NATIVE_TEST_OWN += cert_callback
.PHONY: native-test-cert_callback
native-test-cert_callback:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -framework Foundation -o $(BUILD)/tests/t_cert_callback runtime/tests/t_cert_callback.m ios/cert_callback.m
	timeout 30 $(BUILD)/tests/t_cert_callback
TEST_TARGETS += native-test-cert_callback
