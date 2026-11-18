// 即时存档的带版本字段格式：快照里宿主一侧的表不按 sizeof 整块写，而按「字段号 + 长度 + 值」写，
//   新版 App 读旧快照时按字段号取：新版多出的字段取缺省，旧快照里有、新版不认的字段跳过。只做「新版读旧快照」：
//   段头带格式版本号，读到比自己新的版本即拒绝（旧版不读新快照）。
// 布局：段 = 'S' u32 段名长 段名 u32 版本；之后若干记录 'R' u32 字段数 {u16 字段号 u32 长度 值}；段尾 'E'
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { FILE *f; int err; uint32_t nf; long at; } sfw;   // 写：记录的字段数在记录结束时回填
static inline int sf_w(sfw *w, const void *p, size_t n) { if (!w->err && fwrite(p, 1, n, w->f) != n) w->err = 1; return w->err; }
static inline void sfw_sec(sfw *w, FILE *f, const char *name, uint32_t ver) {
    w->f = f; w->err = 0; w->nf = 0; w->at = -1; uint32_t n = (uint32_t)strlen(name); char t = 'S';
    sf_w(w, &t, 1); sf_w(w, &n, 4); sf_w(w, name, n); sf_w(w, &ver, 4);
}
static inline void sfw_rec(sfw *w) { char t = 'R'; uint32_t z = 0; sf_w(w, &t, 1); w->at = ftell(w->f); sf_w(w, &z, 4); w->nf = 0; }
static inline void sfw_end_rec(sfw *w) {
    if (w->err || w->at < 0) return; long here = ftell(w->f);
    if (fseek(w->f, w->at, SEEK_SET) || fwrite(&w->nf, 4, 1, w->f) != 1 || fseek(w->f, here, SEEK_SET)) w->err = 1; w->at = -1;
}
static inline void sfw_blob(sfw *w, uint16_t id, const void *p, uint32_t n) { sf_w(w, &id, 2); sf_w(w, &n, 4); if (n) sf_w(w, p, n); w->nf++; }
static inline void sfw_u64(sfw *w, uint16_t id, uint64_t v) { sfw_blob(w, id, &v, 8); }
static inline int sfw_end(sfw *w) { char t = 'E'; sf_w(w, &t, 1); return w->err ? -1 : 0; }

// 读：一条记录整条读进来（字段表 + 值缓冲），按字段号取
enum { SF_MAXF = 160 };
typedef struct { FILE *f; int err; uint32_t ver; uint32_t nf; uint16_t id[SF_MAXF]; uint32_t len[SF_MAXF]; uint32_t off[SF_MAXF]; uint8_t *buf; uint32_t cap; } sfr;
// 开段：段名不符 / 版本比本版能读的新（maxver）即失败（-1）；成功回 0，r->ver = 快照里的版本
static inline int sfr_sec(sfr *r, FILE *f, const char *name, uint32_t maxver) {
    memset(r, 0, sizeof *r); r->f = f; char t; uint32_t n; char nm[64];
    if (fread(&t, 1, 1, f) != 1 || t != 'S' || fread(&n, 4, 1, f) != 1 || n >= sizeof nm || fread(nm, 1, n, f) != n) return -1;
    nm[n] = 0; if (strcmp(nm, name) || fread(&r->ver, 4, 1, f) != 1) return -1;
    return r->ver > maxver ? -2 : 0;   // -2：快照比本版新（旧版不读新快照）
}
// 下一条记录：1 = 读到；0 = 段尾；-1 = 坏
static inline int sfr_rec(sfr *r) {
    char t; if (fread(&t, 1, 1, r->f) != 1) return -1; if (t == 'E') return 0; if (t != 'R') return -1;
    uint32_t nf; if (fread(&nf, 4, 1, r->f) != 1 || nf > SF_MAXF) return -1;
    uint32_t used = 0; r->nf = 0;
    for (uint32_t i = 0; i < nf; i++) {
        uint16_t id; uint32_t n; if (fread(&id, 2, 1, r->f) != 1 || fread(&n, 4, 1, r->f) != 1) return -1;
        if (used + n > r->cap) { uint32_t c = (used + n) * 2 + 256; uint8_t *b = realloc(r->buf, c); if (!b) return -1; r->buf = b; r->cap = c; }
        if (n && fread(r->buf + used, 1, n, r->f) != n) return -1;
        r->id[i] = id; r->len[i] = n; r->off[i] = used; used += n; r->nf++;
    }
    return 1;
}
static inline const void *sfr_get(const sfr *r, uint16_t id, uint32_t *n) { for (uint32_t i = 0; i < r->nf; i++) if (r->id[i] == id) { if (n) *n = r->len[i]; return r->buf + r->off[i]; } return NULL; }
static inline uint64_t sfr_u64(const sfr *r, uint16_t id, uint64_t dflt) { uint32_t n; const void *p = sfr_get(r, id, &n); uint64_t v = 0; if (!p || n == 0 || n > 8) return dflt; memcpy(&v, p, n); return v; }
// 按长度取进定长缓冲：快照里短（旧版字段更短）补 0，长截断；没有该字段回 0、out 不动
static inline int sfr_into(const sfr *r, uint16_t id, void *out, uint32_t cap) { uint32_t n; const void *p = sfr_get(r, id, &n); if (!p) return 0; memset(out, 0, cap); memcpy(out, p, n < cap ? n : cap); return 1; }
static inline void sfr_done(sfr *r) { free(r->buf); r->buf = NULL; }

// ---------- 宿主结构的布局指纹（不用手写版本号，改了结构自动变）----------
// clang __builtin_dump_struct 按顺序打出每个字段的名字与类型（含嵌套、数组长度）；这里只哈希格式串与字符串参数（字段名 / 类型名），不哈希数值，
//   所以同一布局的指纹与内容无关、加 / 删 / 改字段指纹即变。快照记下按 sizeof 整块存的宿主结构（游戏内存里的 NVN 对象、图形回放状态等）的指纹，
//   恢复时不同 = 布局变了：有转换函数就转，没有就明确拒绝（C 档），绝不按旧布局硬套。
#include <stdarg.h>
static uint64_t g_sfp_h;
static inline void sfp_mix(const char *s) { for (; s && *s; s++) g_sfp_h = (g_sfp_h ^ (uint8_t)*s) * 0x100000001b3ull; }
static int sfp_printf(const char *fmt, ...) {
    sfp_mix(fmt); va_list ap; va_start(ap, fmt); const char *q = fmt;
    while ((q = strchr(q, '%'))) { q++; while (*q && strchr("0123456789.-+ #lhjzt", *q)) q++;
        if (*q == 's') sfp_mix(va_arg(ap, const char *)); else if (*q == 'p') (void)va_arg(ap, void *);
        else if (*q == 'f' || *q == 'g' || *q == 'e' || *q == 'a') (void)va_arg(ap, double); else if (*q == '%') {} else if (*q) (void)va_arg(ap, long long);
        if (*q) q++; }
    va_end(ap); return 0;
}
// 一律对「同类型的全零静态对象」取：__builtin_dump_struct 会把布尔值、字符串指针的内容当字符串参数传，用真对象会把内容混进指纹
//   （11-17 实测：视频图像表同一二进制前后两次指纹不同）。匿名结构用 SNAP_FP_OF(变量) 取它的类型
#define SNAP_FP_DUMP_(objp) ({ g_sfp_h = 1469598103934665603ull; __builtin_dump_struct((objp), sfp_printf); g_sfp_h ^ (uint64_t)sizeof(*(objp)); })
#define SNAP_FP_TYPE(T) ({ static T sfp_z_; SNAP_FP_DUMP_(&sfp_z_); })
#define SNAP_FP_OF(var) SNAP_FP_TYPE(__typeof__(var))
