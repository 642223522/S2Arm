# native-test-uncaught_exc：未捕获 ObjC 异常的记录（ios/uncaught_exc.m 只用 Foundation，Mac 上直接编）
NATIVE_TEST_OWN += uncaught_exc
.PHONY: native-test-uncaught_exc
native-test-uncaught_exc:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -o $(BUILD)/tests/t_uncaught_exc runtime/tests/t_uncaught_exc.m ios/uncaught_exc.m -framework Foundation
	$(BUILD)/tests/t_uncaught_exc
TEST_TARGETS += native-test-uncaught_exc
