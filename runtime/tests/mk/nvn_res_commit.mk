# native-test-nvn_res_commit：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_res_commit
ifeq ($(S2A_UNAME),Darwin)
# 驻留集改动排队、提交换锁（马车世界缺口 ④，上游参考实现（MIT）0c078130）
$(BUILD)/tests/t_nvn_res_commit: graphics/nvn/tests/t_nvn_res_commit.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_res_commit.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_res_commit
native-test-nvn_res_commit: $(BUILD)/tests/t_nvn_res_commit
	$(BUILD)/tests/t_nvn_res_commit
TEST_TARGETS += native-test-nvn_res_commit
endif
