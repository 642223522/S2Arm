// 首次上传的后台逐页哈希（nvn_mtl.m ph_hash_pages，#b5a081 v0.4.0 回归）：ph_queue 的 GCD 线程上读客体页，页不可访问时不能崩，要回「读不了」让调用方作废这份哈希。
//   期望按页内容手写（不由被测实现反推）：三个宿主页，页 0、页 1 填同一字节、页 2 填另一字节——
//   ① 全可读：返回 1，页 0 与页 1 的哈希相等、页 0 与页 2 不等；
//   ② 页 1 设成不可访问（GPU 改过没回写的页就是这样）：返回 0、进程不崩（旧实现直接读，这里 SIGBUS / SIGSEGV）；
//   ③ 恢复可读后同一调用回到 ①。
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
int nvn_be_test_ph_hash(const void *mem, uint64_t size, uint32_t n, uint64_t *h);
uint64_t nvn_be_test_mem_readable(const void *p, uint64_t n);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
int main(void) { @autoreleasepool {
    size_t pg = (size_t)getpagesize(); uint64_t h[3];
    uint8_t *m = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) { printf("✗ 申请不到 3 页\n"); return 1; }
    memset(m, 0xAA, 2 * pg); memset(m + 2 * pg, 0xBB, pg);
    int r = nvn_be_test_ph_hash(m, 3 * pg, 3, h);
    CHECK(r == 1 && h[0] == h[1] && h[0] != h[2], "① 全可读：返回 %d（应 1），页 0 / 1 哈希%s（应相等）、页 0 / 2 %s（应不等）", r, h[0] == h[1] ? "相等" : "不等", h[0] != h[2] ? "不等" : "相等");
    mprotect(m + pg, pg, PROT_NONE);
    r = nvn_be_test_ph_hash(m, 3 * pg, 3, h);
    CHECK(r == 0, "② 页 1 不可访问：返回 %d（应 0，读不了；不崩）", r);
    mprotect(m + pg, pg, PROT_READ | PROT_WRITE);
    r = nvn_be_test_ph_hash(m, 3 * pg, 3, h);
    CHECK(r == 1 && h[0] == h[1] && h[0] != h[2], "③ 恢复可读：返回 %d（应 1）、页 0 / 1 %s", r, h[0] == h[1] ? "相等" : "不等");
    // ④ 存储尾巴没映射（#b5a081 / #8328e7：不在池里的贴图按全长读，尾巴落进 --- 区）：从起点算起连续可读的长度。期望手算：
    //   末页不可访问 → 2 页；起点在页 1、长度跨到末页 → 1 页；末页解除映射（空洞）→ 2 页
    mprotect(m + 2 * pg, pg, PROT_NONE);
    uint64_t a1 = nvn_be_test_mem_readable(m, 3 * pg), a2 = nvn_be_test_mem_readable(m + pg, 2 * pg);
    CHECK(a1 == 2 * pg && a2 == pg, "④ 末页不可访问：可读 %llu / %llu 字节（应 %zu / %zu）", (unsigned long long)a1, (unsigned long long)a2, 2 * pg, pg);
    munmap(m, 3 * pg);
    uint8_t *q = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (q != MAP_FAILED) { munmap(q + 2 * pg, pg); uint64_t a3 = nvn_be_test_mem_readable(q, 3 * pg);
        CHECK(a3 == 2 * pg, "④ 末页解除映射：可读 %llu 字节（应 %zu）", (unsigned long long)a3, 2 * pg); munmap(q, 2 * pg); }
    printf("%s t_nvn_ph_hash：后台逐页哈希 可读 / 不可访问不崩 / 恢复 / 尾巴可读长度 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}}
