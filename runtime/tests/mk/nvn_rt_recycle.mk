# native-test-nvn_rt_recycle：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rt_recycle
ifeq ($(S2A_UNAME),Darwin)
# 回收贴图堆（马车世界缺口 ③，上游参考实现（MIT）707cac95）：Metal 4 进堆复用 / Metal 3 与开关关不进堆
$(BUILD)/tests/t_nvn_rt_recycle: graphics/nvn/tests/t_nvn_rt_recycle.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_rt_recycle.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rt_recycle
native-test-nvn_rt_recycle: $(BUILD)/tests/t_nvn_rt_recycle
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_rt_recycle
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_rt_recycle
	NXGAL_BE=mtl4 DM_NVN_RT_RECYCLE=0 $(BUILD)/tests/t_nvn_rt_recycle
TEST_TARGETS += native-test-nvn_rt_recycle
endif
