# native-test-nvn_submit_rt：提交线程实时声明的判定是纯函数（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_submit_rt
NVN_SUBMIT_RT_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_submit_rt
native-test-nvn_submit_rt:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_SUBMIT_RT_DIR) -o $(BUILD)/tests/t_nvn_submit_rt runtime/tests/t_nvn_submit_rt.c -lm
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_SUBMIT_RT_DIR)/nvn_submit_rt.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_submit_rt.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_submit_rt.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_submit_rt
TEST_TARGETS += native-test-nvn_submit_rt
