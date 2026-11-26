// BC → ASTC 预转包读取与平面键（说明与包格式见 gal_astc.h）。参考 brad-n/TVPort（MIT）dm/gfx/tex/nvn_astc_cache.m 的只读包：
//   头 + 负载 + 末尾按键排序的索引、索引映射后二分、负载按需 pread（几百 MB 的包不常驻内存）、整包校验不过即整包不用。
//   本仓库的包格式更简（无逐项摘要 / 压缩），键口径按 GAL 线性布局的平面重定。纯 C。
#include "gal_astc.h"
#include "gal_formats.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct gal_astc_pack { int fd; uint64_t count, ioff; const uint8_t *index; void *map; size_t map_len; };

static uint64_t le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static gal_astc_pack *bad(int fd, void *map, size_t len, char *why, size_t n, const char *msg) {
    if (why && n) snprintf(why, n, "%s", msg);
    if (map) munmap(map, len);
    if (fd >= 0) close(fd);
    return NULL;
}

gal_astc_pack *gal_astc_open(const char *path, char *why, size_t n) {
    if (!path || !*path) return bad(-1, NULL, 0, why, n, "没给路径");
    int fd = open(path, O_RDONLY | O_CLOEXEC); struct stat st;
    if (fd < 0) return bad(-1, NULL, 0, why, n, "打不开");
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) return bad(fd, NULL, 0, why, n, "不是普通文件");
    uint8_t h[GAL_ASTC_HEAD];
    if ((uint64_t)st.st_size < GAL_ASTC_HEAD || pread(fd, h, sizeof h, 0) != (ssize_t)sizeof h) return bad(fd, NULL, 0, why, n, "比头还短");
    if (memcmp(h, "S2ABCAST", 8)) return bad(fd, NULL, 0, why, n, "魔数不对");
    if (le32(h + 8) != 1 || le32(h + 12) != GAL_ASTC_ENT) return bad(fd, NULL, 0, why, n, "版本或索引项长度不认识");
    uint64_t count = le64(h + 16), ioff = le64(h + 24), fsz = le64(h + 32);
    if (fsz != (uint64_t)st.st_size) return bad(fd, NULL, 0, why, n, "头里记的文件长度与实际不符（截断或拼接）");
    if (h[40] != 4 || h[41] != 4) return bad(fd, NULL, 0, why, n, "块不是 4x4");
    if (ioff < GAL_ASTC_HEAD || ioff > fsz || count > (fsz - ioff) / GAL_ASTC_ENT || count * GAL_ASTC_ENT != fsz - ioff) return bad(fd, NULL, 0, why, n, "索引位置 / 项数与文件长度对不上");
    void *map = NULL; const uint8_t *index = NULL; size_t len = 0;
    if (count) {
        size_t page = (size_t)getpagesize(), lead = (size_t)(ioff % page); len = lead + (size_t)(count * GAL_ASTC_ENT);
        map = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, (off_t)(ioff - lead));
        if (map == MAP_FAILED) return bad(fd, NULL, 0, why, n, "索引映射失败");
        index = (const uint8_t *)map + lead;
    }
    for (uint64_t i = 0; i < count; i++) {   // 严格升序、负载落在头与索引之间、16 字节对齐、长度是整块
        const uint8_t *e = index + i * GAL_ASTC_ENT; uint64_t off = le64(e + 32), sz = le64(e + 40);
        if (i && memcmp(e - GAL_ASTC_ENT, e, 32) >= 0) return bad(fd, map, len, why, n, "索引没按键严格升序");
        if (off < GAL_ASTC_HEAD || (off & 15) || !sz || (sz & 15) || off > ioff || sz > ioff - off) return bad(fd, map, len, why, n, "索引项指到负载区外");
    }
    gal_astc_pack *p = calloc(1, sizeof *p);
    if (!p) return bad(fd, map, len, why, n, "内存不足");
    p->fd = fd; p->count = count; p->ioff = ioff; p->index = index; p->map = map; p->map_len = len;
    return p;
}
void gal_astc_close(gal_astc_pack *p) { if (!p) return; if (p->map) munmap(p->map, p->map_len); close(p->fd); free(p); }
uint64_t gal_astc_count(const gal_astc_pack *p) { return p ? p->count : 0; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void gal_astc_key(uint32_t family, uint32_t width, uint32_t height, const void *bc, size_t len, uint8_t key[32]) {
    static const char tag[] = "s2a-bc-astc-v1";
    uint8_t f[12]; uint32_t v[3] = {family, width, height};
    for (int i = 0; i < 3; i++) for (int j = 0; j < 4; j++) f[i * 4 + j] = (uint8_t)(v[i] >> (8 * j));
    CC_SHA256_CTX c; CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, tag, (CC_LONG)(sizeof tag - 1));
    CC_SHA256_Update(&c, f, sizeof f);
    const uint8_t *b = bc;
    while (len) { CC_LONG k = len > (1u << 30) ? (1u << 30) : (CC_LONG)len; CC_SHA256_Update(&c, b, k); b += k; len -= k; }
    CC_SHA256_Final(key, &c);
}
#pragma clang diagnostic pop

static const uint8_t *find_ent(const gal_astc_pack *p, const uint8_t key[32]) {
    if (!p) return NULL;
    uint64_t lo = 0, hi = p->count;
    while (lo < hi) {
        uint64_t mid = lo + (hi - lo) / 2; const uint8_t *e = p->index + mid * GAL_ASTC_ENT; int c = memcmp(e, key, 32);
        if (!c) return e;
        if (c < 0) lo = mid + 1; else hi = mid;
    }
    return NULL;
}
int gal_astc_find(const gal_astc_pack *p, const uint8_t key[32], uint64_t *size) {
    const uint8_t *e = find_ent(p, key); if (!e) return 0;
    if (size) *size = le64(e + 40);
    return 1;
}
int gal_astc_read(const gal_astc_pack *p, const uint8_t key[32], void *dst, uint64_t want) {
    const uint8_t *e = find_ent(p, key); if (!e || le64(e + 40) != want) return 0;
    uint64_t off = le64(e + 32);
    for (uint64_t got = 0; got < want;) {
        ssize_t r = pread(p->fd, (uint8_t *)dst + got, (size_t)(want - got), (off_t)(off + got));
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return 0;
        got += (uint64_t)r;
    }
    return 1;
}

int gal_astc_family(int32_t f) {
    switch (f) {
    case F_Bc1RgbaUnorm: case F_Bc1RgbaSrgb: return GAL_ASTC_FAM_BC1;
    case F_Bc2Unorm: case F_Bc2Srgb: return GAL_ASTC_FAM_BC2;
    case F_Bc3Unorm: case F_Bc3Srgb: return GAL_ASTC_FAM_BC3;
    case F_Bc5Unorm: return GAL_ASTC_FAM_BC5U;
    case F_Bc7Unorm: case F_Bc7Srgb: return GAL_ASTC_FAM_BC7;
    }
    return GAL_ASTC_FAM_NONE;
}
