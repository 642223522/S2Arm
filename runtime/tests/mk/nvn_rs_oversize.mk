# native-test-nvn_rs_oversize：超贴图上限缩建（nvn_rscale.inc 文件头）。生产 NVN bootstrap、录制、Metal 3/4 回放与公开读回
NATIVE_TEST_OWN += nvn_rs_oversize
ifeq ($(S2A_UNAME),Darwin)
# 单测把 nvn_mtl.m 编进本单元（直接调 rs_rescale_to 核退不回原尺寸），依赖与编译选项同 t_nvn_rscale
$(BUILD)/tests/t_nvn_rs_oversize: graphics/nvn/tests/t_nvn_rs_oversize.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_rs_oversize.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rs_oversize
native-test-nvn_rs_oversize: $(BUILD)/tests/t_nvn_rs_oversize
	timeout 120 $(BUILD)/tests/t_nvn_rs_oversize
	NXGAL_BE=mtl3 timeout 120 $(BUILD)/tests/t_nvn_rs_oversize
TEST_TARGETS += native-test-nvn_rs_oversize
endif
