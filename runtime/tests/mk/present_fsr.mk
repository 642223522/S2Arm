# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 直连上屏 AMD FSR 1（S2A_SCALING_FILTER=Fsr，graphics/nvn/gfx/nvn/nvn_present_fsr.inc）：生产 nvn_mtl.m 源码 + 真 Metal 设备，离屏跑真的上屏编码，不开窗口。
#   GPU 的 EASU / RCAS 逐像素对独立的 CPU 参考（graphics/nvn/tests/fsr1_ref.h，按 AMD 公式），加手算性质与负对照；Metal 4 / Metal 3 × 不带 / 带抗锯齿各跑一遍，
#   再核 S2A_SCALING_FILTER_LEVEL：合法值进系数（100 → 1，0 → 2^-1.49985 = 0.353590），非法值在 mtl_init 里（起局，第一次上屏之前）报红退出。
#   开销读数（不进门禁）：$(PRESENT_FSR_BINARY) bench，NXGAL_BE=mtl3 换后端
NATIVE_TEST_OWN += present_fsr
ifeq ($(S2A_UNAME),Darwin)
PRESENT_FSR_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
PRESENT_FSR_BINARY ?= $(BUILD)/tests/t_nvn_present_fsr
$(PRESENT_FSR_BINARY): graphics/nvn/tests/t_present_fsr.m graphics/nvn/tests/fsr1_ref.h $(PRESENT_FSR_SOURCE) $(NVN_MTL_DEPS) $(dir $(PRESENT_FSR_SOURCE))nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include -Igraphics/nvn/tests \
	  -DPRESENT_FSR_SOURCE='"$(abspath $(PRESENT_FSR_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_present_fsr.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-present_fsr
native-test-present_fsr: $(PRESENT_FSR_BINARY)
	env -u NXGAL_BE -u S2A_SCALING_FILTER_LEVEL S2A_ANTI_ALIASING=None $(PRESENT_FSR_BINARY)
	env -u S2A_SCALING_FILTER_LEVEL NXGAL_BE=mtl3 S2A_ANTI_ALIASING=None $(PRESENT_FSR_BINARY)
	env -u NXGAL_BE -u S2A_SCALING_FILTER_LEVEL S2A_ANTI_ALIASING=SmaaHigh $(PRESENT_FSR_BINARY)
	env -u S2A_SCALING_FILTER_LEVEL NXGAL_BE=mtl3 S2A_ANTI_ALIASING=SmaaMedium $(PRESENT_FSR_BINARY)
	env -u NXGAL_BE S2A_SCALING_FILTER_LEVEL=100 $(PRESENT_FSR_BINARY) level 2>&1 | grep -F 'LEVEL 100 con=1.000000'
	env -u NXGAL_BE S2A_SCALING_FILTER_LEVEL=0 $(PRESENT_FSR_BINARY) level 2>&1 | grep -F 'LEVEL 0 con=0.353590'
	env -u NXGAL_BE S2A_SCALING_FILTER_LEVEL=55 $(PRESENT_FSR_BINARY) init 2>&1 | grep -Fx 'INIT OK'
	@for bad in 101 -1 80.5 abc ''; do \
	  out=$$(env -u NXGAL_BE S2A_SCALING_FILTER_LEVEL="$$bad" $(PRESENT_FSR_BINARY) init 2>&1); rc=$$?; \
	  if [ $$rc -ne 0 ] && printf '%s' "$$out" | grep -qF "invalid S2A_SCALING_FILTER_LEVEL=$$bad" && ! printf '%s' "$$out" | grep -qF 'INIT OK' && ! printf '%s' "$$out" | grep -qF '直连画面设置'; then \
	    echo "PASS S2A_SCALING_FILTER_LEVEL='$$bad' 在 mtl_init 里报红退出（退出码 $${rc}，没到第一次上屏）"; \
	  else echo "FAIL S2A_SCALING_FILTER_LEVEL='$$bad' 没有在起局报红退出（退出码 $${rc}）"; exit 1; fi; done
	@echo "✓ native-test-present_fsr"
TEST_TARGETS += native-test-present_fsr
endif
