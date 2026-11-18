# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_storage_copy：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_storage_copy
ifeq ($(S2A_UNAME),Darwin)
# 纹理上传后的池字节搬移：CPU / GPU 源、局部更新、重叠源、两种 GOB 次序、BC mip / 数组 / 三维，Metal 4 / 3 × 编码线程关 / 开
$(BUILD)/tests/t_nvn_storage_copy: graphics/nvn/tests/t_nvn_storage_copy.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_storage_copy.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_storage_copy
native-test-nvn_storage_copy: $(BUILD)/tests/t_nvn_storage_copy
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_storage_copy
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_storage_copy
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_storage_copy
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_storage_copy
TEST_TARGETS += native-test-nvn_storage_copy
endif
