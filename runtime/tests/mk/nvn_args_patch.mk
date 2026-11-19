# native-test-nvn_args_patch：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_args_patch
ifeq ($(S2A_UNAME),Darwin)
# 参数块只换统一缓冲就打补丁（11-13，照 nxnative adaff735）
$(BUILD)/tests/t_nvn_args_patch: graphics/nvn/tests/t_nvn_args_patch.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_args_patch.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_args_patch
native-test-nvn_args_patch: $(BUILD)/tests/t_nvn_args_patch
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_args_patch
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_args_patch
TEST_TARGETS += native-test-nvn_args_patch
endif
