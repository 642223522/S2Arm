# native-test-dirty_span_index：写跟踪「取范围」有序索引（nvn_dirty.c find_span，#1133）——
# 与线性扫逐位一致（含「没有」/ 边界 / 重叠 / 嵌套 / 同起点）/ 索引与槽位表一致（有序、子树最大 end、条目 = 现存范围）/ 写者收工代际为偶数且变大 /
# 表一变（登记 / 注销 / 复用槽位 / 换底 / 重置会话）答案跟着变 / 奇数代际与查询中途有写者插进来时不信索引 / 超上限与索引不可用时退回线性扫 / 并发下读者不漏永远在的范围。
# 直接包含生产源码（读静态的 find_span / find_span_scan / 索引内部，也让变异测试能换成变异副本：graphics/nvn/tests/dirty_span_memo_mutation_test.py）。不需要 GPU / 游戏。
NATIVE_TEST_OWN += dirty_span_index
.PHONY: native-test-dirty_span_index
native-test-dirty_span_index:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -pthread -o $(BUILD)/tests/t_dirty_span_index graphics/nvn/tests/t_dirty_span_index.c
	$(BUILD)/tests/t_dirty_span_index
TEST_TARGETS += native-test-dirty_span_index
