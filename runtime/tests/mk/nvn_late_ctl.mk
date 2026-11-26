# native-test-nvn_late_ctl：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_late_ctl
ifeq ($(S2A_UNAME),Darwin)
# D-K3DA：首用才算键的 Switch 1 着色器用 SetShaders 时自持的控制段（游戏随后复用那块内存）。
$(BUILD)/tests/t_nvn_late_ctl: graphics/nvn/tests/t_nvn_late_ctl.c graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_late_ctl.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -framework Security -framework CoreFoundation -lcompression -lc++
.PHONY: native-test-nvn_late_ctl
native-test-nvn_late_ctl: $(BUILD)/tests/t_nvn_late_ctl
	timeout 60 $(BUILD)/tests/t_nvn_late_ctl
TEST_TARGETS += native-test-nvn_late_ctl
endif
