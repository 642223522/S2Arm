# native-test-nvn_late_key：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_late_key
ifeq ($(S2A_UNAME),Darwin)
# D-WQPH：SetShaders 时代码区不在内存池的着色器，首用取键时交给首遇现编登记。
$(BUILD)/tests/t_nvn_late_key: graphics/nvn/tests/t_nvn_late_key.c graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_late_key.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_late_key
native-test-nvn_late_key: $(BUILD)/tests/t_nvn_late_key
	timeout 60 $(BUILD)/tests/t_nvn_late_key
TEST_TARGETS += native-test-nvn_late_key
endif
