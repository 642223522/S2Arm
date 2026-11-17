# native-test-nvn_tensor_widen：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 张量核网络顶替在满屏放宽下挑不出输入时几时退回 16:9（graphics/nvn/gfx/nvn/tensor_widen.h，#726）：纯函数
NATIVE_TEST_OWN += nvn_tensor_widen
.PHONY: native-test-nvn_tensor_widen
native-test-nvn_tensor_widen:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_nvn_tensor_widen graphics/nvn/tests/t_nvn_tensor_widen.c
	$(BUILD)/tests/t_nvn_tensor_widen
TEST_TARGETS += native-test-nvn_tensor_widen
