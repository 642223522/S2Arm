# native-test-nvn_pkg_unreadable：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pkg_unreadable
ifeq ($(S2A_UNAME),Darwin)
# 有池指针、存储读不了的贴图走 CPU 上传不越界读（#a4a895 / #b5a081）
$(BUILD)/tests/t_nvn_pkg_unreadable: graphics/nvn/tests/t_nvn_pkg_unreadable.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pkg_unreadable.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pkg_unreadable
native-test-nvn_pkg_unreadable: $(BUILD)/tests/t_nvn_pkg_unreadable
	$(BUILD)/tests/t_nvn_pkg_unreadable
TEST_TARGETS += native-test-nvn_pkg_unreadable
endif
