# 驻留集按来源统计移出与当前驻留（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_res_site.m）
NATIVE_TEST_OWN += res_site
ifeq ($(S2A_UNAME),Darwin)
RES_SITE_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
RES_SITE_BINARY ?= $(BUILD)/tests/t_nvn_res_site
$(RES_SITE_BINARY): graphics/nvn/tests/t_res_site.m $(RES_SITE_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DRES_SITE_SOURCE='"$(abspath $(RES_SITE_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_res_site.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-res_site
native-test-res_site: $(RES_SITE_BINARY)
	$(RES_SITE_BINARY)
TEST_TARGETS += native-test-res_site
endif
