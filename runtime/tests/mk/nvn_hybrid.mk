# native-test-nvn_hybrid：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_hybrid
ifeq ($(S2A_UNAME),Darwin)
# 混合管线：首遇没有精确管线的绘制用拉取管线先画（nvn_hybrid.inc）；选择、布局块、载入、真画像素与精确管线一致。
#   拉取库的前导从翻译器 Pull.cs 的 Prelude 原样摘出（两半同一份 dm_vlayout / dm_fetch），编成 <key>_bp.metallib 放在没有容器的库目录里由宿主 pull_fn 载入
NVN_HYBRID_LIB := $(BUILD)/tests/nvn_hybrid
$(NVN_HYBRID_LIB)/pull_prelude.metal: graphics/tools/direct/dsh/Pull.cs
	@mkdir -p $(dir $@)
	awk '/public const string Prelude = """/{f=1;next} /^""";/{f=0} f' $< > $@.tmp && grep -q 'struct dm_vlayout' $@.tmp && grep -q 'dm_fetch' $@.tmp && mv $@.tmp $@
$(NVN_HYBRID_LIB)/aaaaaaaaaaaaaaaa_bp.metallib: graphics/nvn/tests/t_nvn_hybrid_bp.metal $(NVN_HYBRID_LIB)/pull_prelude.metal
	xcrun -sdk macosx metal -I$(NVN_HYBRID_LIB) $< -o $@
$(BUILD)/tests/t_nvn_hybrid: graphics/nvn/tests/t_nvn_hybrid.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_hybrid.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_hybrid
native-test-nvn_hybrid: $(BUILD)/tests/t_nvn_hybrid $(NVN_HYBRID_LIB)/aaaaaaaaaaaaaaaa_bp.metallib
	T_HYBRID_LIB=$(abspath $(NVN_HYBRID_LIB)) $(BUILD)/tests/t_nvn_hybrid
TEST_TARGETS += native-test-nvn_hybrid
endif
