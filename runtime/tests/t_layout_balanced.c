// Android's production layout adapter: legacy balanced mode and default budget.
#include "../src/native.h"
#include "../../android/native/runtime/platform/layout_android.inc"
uint64_t s2a_app_pool(void) { return 0xCD500000ull; } void s2a_app_pool_set(uint64_t v) { (void)v; }   // layout.c 替身（本测不链 layout.c；Switch 池）
#include <assert.h>
#include <unistd.h>
#define GB (1ull << 30)
#define MB (1ull << 20)
int main(void) {
    s2a_layout L;
    const uint64_t W = 0x7000000000ull;
#if defined(S2A_VAMM_BALANCED) && S2A_VAMM_BALANCED
    s2a_layout_requirements req = {.alias_gb=63, .heap_size=32*MB};
    assert(s2a_android_layout_need(3, 80*MB, &req) == 63*GB);
    assert(!s2a_android_layout_compute(3, 80*MB, &req, W, 64*GB, &L));
    assert(L.heap_size == 6*GB && L.win_size == 63*GB);
    assert(L.alias_base + L.alias_size <= L.stack_base);
    assert(L.heap_base + L.heap_size <= W + L.win_size);
    assert(s2a_android_layout_compute(3, 80*MB, &req, W, 62*GB, &L) == -2);
    assert(!s2a_android_layout_compute(3, 0, &req, W, 64*GB, &L));
    assert(L.heap_size == 6*GB && L.win_size == 32*GB);
#else
    s2a_layout_requirements req = {.heap_size=S2A_HEAP_DEFAULT};
    const char *why = NULL; char note[256];
    char filename[] = "/tmp/s2a-layout-test-XXXXXX";
    int fd = mkstemp(filename); assert(fd >= 0);
    FILE *file = fdopen(fd, "w"); assert(file);
    assert(fprintf(file, "版本\t2\n程序号\t0100000000000001\n构建号\t0123456789abcdef0123456789abcdef\n别名区GB\t60\n普通堆MB\t3284\n") > 0);
    assert(!fclose(file));
    assert(!s2a_android_layout_requirements_read(filename, 0x0100000000000001ull, &req, &why));
    assert(req.alias_gb == 60 && req.heap_size == S2A_HEAP_DEFAULT);
    assert(s2a_android_layout_requirements_read(filename, 0x0100000000000002ull, &req, &why) == -1);
    // 11-03 出包判「上限不定」多两行（tools/addr_need.py）：安卓认得、照读别名区；只有一行（缺原因 / 缺上限）是坏表
    file = fopen(filename, "a"); assert(file && fprintf(file, "别名区上限\t不定\n") > 0 && !fclose(file));
    assert(s2a_android_layout_requirements_read(filename, 0x0100000000000001ull, &req, &why) == -1);
    file = fopen(filename, "a"); assert(file && fprintf(file, "上限不定原因\t只占地址、尺寸非常量的申请 1 处：main+0x123008 读内存（取数@0x2c4a298）\n") > 0 && !fclose(file));
    assert(!s2a_android_layout_requirements_read(filename, 0x0100000000000001ull, &req, &why));
    assert(req.alias_gb == 60 && req.heap_size == S2A_HEAP_DEFAULT);
    assert(!unlink(filename));
    req = (s2a_layout_requirements){.heap_size=S2A_HEAP_DEFAULT};
    assert(!s2a_android_layout_split(&req, 0, &why, note, sizeof note));
    // 别名区未测按预算推：72 GiB − 固定 2146 MiB − 堆 3284 MiB = 68298 MiB，向下取整 66 GiB，封顶 63
    assert(req.alias_gb == 63 && req.heap_size == S2A_HEAP_DEFAULT);
    // 需求手算：别名区 63 GiB + TLS/保护页 2 MiB + 栈区 2 GiB（Horizon 39 位真值）+ 共享余量 96 MiB + 堆 3284 MiB
    uint64_t need = s2a_android_layout_need(3, 80*MB, &req);
    assert(S2A_HEAP_DEFAULT == 3284*MB && need == 63*GB + 2*MB + 2*GB + 96*MB + 3284*MB);
    assert(!s2a_android_layout_compute(3, 80*MB, &req, W, 72*GB, &L));
    assert(L.win_size == need && L.heap_size == S2A_HEAP_DEFAULT);
    assert(L.stack_size == 2*GB && L.stack_base == W + 63*GB + 2*MB && L.heap_base == L.stack_base + 2*GB);   // 栈区写死 128 MiB 时 SDK 建线程挑不出位置（奥日开局中止）
    assert(L.aslr_base == L.stack_base && L.aslr_size == 2*GB + 96*MB + 3284*MB);
    assert(L.alias_base + L.alias_size <= L.stack_base);
    assert(L.heap_base + L.heap_size <= W + L.win_size);
    assert(s2a_android_layout_compute(3, 80*MB, &req, W, need-2*MB, &L) == -2);
    assert(s2a_android_layout_compute(2, 80*MB, &req, W, 64*GB, &L) == -1);
#endif
    puts("✓ t_layout_balanced");
    return 0;
}
