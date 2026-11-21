// 即时存档：客体内存文件后备里「已写回文件、不在内存里」的页怎么找（snapshot.c dump_mem 用，单测 runtime/tests/t_snap_extent.c 与宿主自检同一份）。
//   不用 lseek SEEK_DATA / SEEK_HOLE：文件还有可写共享映射时 APFS 把整个文件都报成数据（1 GB 稀疏文件只写两页、实际占 32 KB，映射开着时
//   SEEK_HOLE(0) = 文件末尾，解映射重开才报 16 KB），存档于是把整个窗口几十 GB 逐页读回判零。改问文件实际分配的块（F_LOG2PHYS_EXT：
//   空洞回物理位置 -1 和到下一段数据的长度，映射开着也准）。还没写回的脏页没有块（报空洞），但它们驻留、mincore 照样报。
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// 后备文件从 off 起这一段：有数据回 1、空洞回 0（*len = 这一段连续多长，≤ max）；查不了回 -1
static inline int snap_file_extent(int fd, off_t off, off_t max, off_t *len) {
    struct log2phys l = {0}; l.l2p_contigbytes = max; l.l2p_devoffset = off;
    if (fcntl(fd, F_LOG2PHYS_EXT, &l) || l.l2p_contigbytes <= 0) return -1;
    *len = l.l2p_contigbytes < max ? l.l2p_contigbytes : max;
    return l.l2p_devoffset != -1;
}

typedef struct { uint64_t nfile, next, bext; int fallback, err; } snap_file_stat;
// 文件偏移 foff 起 np 页（每页 pg 字节）对应 vec（mincore 结果）：文件里有数据、不驻留也不换出的页补上 MINCORE_PAGED_OUT（= 要读、要存）。
//   查不了（文件系统不支持 / 被拒）剩下整段按有数据（慢，但不漏写回过的页），st->fallback 计次、st->err 记首个 errno。
//   progress：每段回调一次（看门狗）；broken：单测负对照用，1 = 一页都不标（应测出漏页）
static inline void snap_file_mark(int fd, off_t foff, size_t np, uint64_t pg, char *vec, snap_file_stat *st, void (*progress)(void), int broken) {
    for (off_t o = foff, end = foff + (off_t)(np * pg); o < end; ) {
        if (progress) progress();
        off_t len; int data = snap_file_extent(fd, o, end - o, &len);
        if (data < 0) { if (!st->fallback++) st->err = errno; data = 1; len = end - o; }
        else if (data) { st->next++; st->bext += (uint64_t)len; }
        if (data && !broken) for (off_t q = o & ~(off_t)(pg - 1); q < o + len; q += pg) { size_t i = (size_t)((uint64_t)(q - foff) / pg);
            if (i < np && !(vec[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) { vec[i] |= MINCORE_PAGED_OUT; st->nfile++; } }
        o += len;
    }
}

static inline int snap_page_zero(const uint8_t *p, uint64_t pg) { const uint64_t *q = (const uint64_t *)p; for (size_t i = 0; i < pg / 8; i++) if (q[i]) return 0; return 1; }
// 自检（单测与宿主 S2A_SNAP_EXTENT_SELFTEST=1 同一份）：在 dir 下造 48 页的共享映射后备文件，页 1/5/6/20/47 写非零、10/11 写零，写回并清出内存
//   （msync MS_SYNC + MS_INVALIDATE：只存在于文件里）；之后页 30 写非零不写回（驻留脏页）；其余是空洞。旧方法（SEEK_DATA 报的数据区里不驻留的页
//   全读）与新方法（snap_file_mark）各算一遍「要存的页」（驻留 / 被标），断言：新方法要存的页包含旧方法要存的每一个非零页（漏 0）；
//   期望按构造手写：要存的非零页恰为 {1,5,6,20,30,47}；被标的（文件里有数据、不驻留）恰为 {1,5,6,10,11,20,47}。回 0 全过；msg 写一行读数
static inline int s2a_snap_extent_selftest(const char *dir, int broken, char *msg, size_t msgn) {
    const uint64_t pg = 0x4000; enum { N = 48 };
    char path[1024]; snprintf(path, sizeof path, "%s/s2a_extent_selftest.%d", dir && *dir ? dir : "/tmp", (int)getpid());
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600); if (fd < 0) { snprintf(msg, msgn, "建文件失败 errno %d", errno); return -1; }
    unlink(path);
    if (ftruncate(fd, (off_t)(N * pg))) { close(fd); snprintf(msg, msgn, "ftruncate 失败 errno %d", errno); return -1; }
    uint8_t *m = mmap(NULL, N * pg, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (m == MAP_FAILED) { close(fd); snprintf(msg, msgn, "映射失败 errno %d", errno); return -1; }
    static const int nz[] = {1, 5, 6, 20, 47}, zw[] = {10, 11};
    for (size_t k = 0; k < sizeof nz / sizeof *nz; k++) memset(m + nz[k] * pg, 0x5A + (int)k, pg);
    for (size_t k = 0; k < sizeof zw / sizeof *zw; k++) memset(m + zw[k] * pg, 0, pg), m[zw[k] * pg] = 1, m[zw[k] * pg] = 0;   // 写过（分配了块）但内容是零
    msync(m, N * pg, MS_SYNC); msync(m, N * pg, MS_INVALIDATE);
    memset(m + 30 * pg, 0x77, pg);   // 驻留脏页（不写回）
    char vec[N], vold[N], vnew[N]; if (mincore(m, N * pg, vec)) { munmap(m, N * pg); close(fd); snprintf(msg, msgn, "mincore 失败 errno %d", errno); return -1; }
    int nres = 0; for (int i = 0; i < N; i++) nres += !!(vec[i] & MINCORE_INCORE);
    memcpy(vold, vec, N); memcpy(vnew, vec, N);
    for (off_t o = 0, end = (off_t)(N * pg); o < end; ) {   // 旧方法
        off_t d = lseek(fd, o, SEEK_DATA); if (d < 0 || d >= end) break;
        off_t h = lseek(fd, d, SEEK_HOLE); if (h < 0 || h > end) h = end;
        for (off_t q = d & ~(off_t)(pg - 1); q < h; q += pg) { size_t i = (size_t)((uint64_t)q / pg); if (i < N && !(vold[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) vold[i] |= MINCORE_PAGED_OUT; }
        o = h; }
    snap_file_stat st = {0}; snap_file_mark(fd, 0, N, pg, vnew, &st, NULL, broken);
    int old_nz = 0, new_nz = 0, miss = 0, marked = 0, bad_nz = 0, bad_mark = 0;
    for (int i = 0; i < N; i++) {
        int z = snap_page_zero(m + i * pg, pg), so = !!(vold[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT)), sn = !!(vnew[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT));
        int mk = !(vec[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT)) && (vnew[i] & MINCORE_PAGED_OUT);
        int want_nz = i == 1 || i == 5 || i == 6 || i == 20 || i == 30 || i == 47, want_mk = i == 1 || i == 5 || i == 6 || i == 10 || i == 11 || i == 20 || i == 47;
        old_nz += so && !z; new_nz += sn && !z; miss += so && !z && !sn; marked += mk;
        bad_nz += (sn && !z) != want_nz; bad_mark += mk != want_mk;
    }
    munmap(m, N * pg); close(fd);
    snprintf(msg, msgn, "开始时驻留 %d 页；旧方法要存的非零页 %d、新方法 %d、漏 %d；被标 %d 页（期望 7）、非零集合不符 %d、被标集合不符 %d；按块查有数据 %llu 段、兜底 %d 次（errno %d）",
             nres, old_nz, new_nz, miss, marked, bad_nz, bad_mark, (unsigned long long)st.next, st.fallback, st.err);
    return miss || bad_nz || (!st.fallback && bad_mark) ? 1 : 0;   // 走了兜底（整段按有数据）时被标集合必然多，只要求不漏
}
