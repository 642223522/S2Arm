# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Real EGL/GL registration, native host, Widen and Metal; no replacement symbols.
NATIVE_TEST_OWN += egl_core
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_egl_core: graphics/nvn/tests/t_egl_core.m graphics/nvn/tests/gl/t_session_resources.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn/include -o $@ $< graphics/nvn/tests/gl/t_session_resources.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-egl_core
native-test-egl_core: $(BUILD)/tests/t_egl_core
	$(BUILD)/tests/t_egl_core
	@echo '✓ t_egl_core'
TEST_TARGETS += native-test-egl_core
endif
