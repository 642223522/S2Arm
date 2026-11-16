# native-test-nvn_ph_hash：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_ph_hash
ifeq ($(shell uname -s),Darwin)
# 首次上传后台逐页哈希：页不可访问时回「读不了」、不崩（nvn_mtl.m ph_hash_pages，#b5a081）
$(BUILD)/tests/t_nvn_ph_hash: graphics/nvn/tests/t_nvn_ph_hash.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_ph_hash.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ph_hash
native-test-nvn_ph_hash: $(BUILD)/tests/t_nvn_ph_hash
	$(BUILD)/tests/t_nvn_ph_hash
TEST_TARGETS += native-test-nvn_ph_hash
endif
