# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
#
# native-test-nvn_pfview：Metal 贴图视图格式兼容性判据（nvn_pfview.h），不需要 GPU / 游戏。
# 11-09 一款竞速游戏（程序号 0100152000022000）/ iPhone 14 Pro Max：无 BC 设备上 BC3 贴图解码成 RGBA8Unorm，游戏仍按 RGBA32Uint
# 块视图挂成渲染目标，Metal 校验直接 abort()。修好后用这条单测钉住判据，见 graphics/nvn/tests/t_pfview.m。
NATIVE_TEST_OWN += nvn_pfview
.PHONY: native-test-nvn_pfview
native-test-nvn_pfview:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -o $(BUILD)/tests/t_pfview graphics/nvn/tests/t_pfview.m \
	  -framework Metal -framework Foundation
	$(BUILD)/tests/t_pfview
TEST_TARGETS += native-test-nvn_pfview
