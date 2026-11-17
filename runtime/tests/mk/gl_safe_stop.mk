# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# GPU 安全停后 GL 提交不重复 leave 完成组（D-TMM9）；真 EGL / GL / Metal。
NATIVE_TEST_OWN += gl_safe_stop
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_gl_safe_stop: graphics/nvn/tests/t_gl_safe_stop.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn/include -o $@ $< $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-gl_safe_stop
native-test-gl_safe_stop: $(BUILD)/tests/t_gl_safe_stop
	@# 安全停后宿主照产品行为优雅收局、退出码 86（graphics/nvn/host_adapt.m s2a_gpu_safe_stop）；0 / 86 都算过，旧代码在收局前就 Trace/BPT trap（信号 5）
	$(BUILD)/tests/t_gl_safe_stop; rc=$$?; [ $$rc -eq 0 ] || [ $$rc -eq 86 ] || { echo "✗ t_gl_safe_stop rc=$$rc"; exit 1; }
	@echo '✓ t_gl_safe_stop'
TEST_TARGETS += native-test-gl_safe_stop
endif
