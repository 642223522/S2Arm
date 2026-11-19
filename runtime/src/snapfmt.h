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
static __attribute__((unused)) int sfp_printf(const char *fmt, ...) {
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

// ---------- 宿主结构的完整布局（跨 App 版本按字段转换）----------
// 指纹只答「变没变」；变了时要转，得知道旧版每个字段在哪。快照里连同指纹存下每个整块结构的完整布局（字段路径 / 类型名 / 偏移 / 长度 / 种类），
//   新版恢复时按字段路径一一对上：同类型同长度原样搬，整数换宽度按值搬（放不下点名），浮点换精度按值搬，旧版有新版没有的丢掉，新版新加的取缺省；
//   有一个字段对不上（种类变了、联合 / 位域段内容变了、数组元素长度变了）就整体不转、照旧拒绝。对所有结构、所有版本成立，不手写逐版转换。
// 偏移怎么来：__builtin_dump_struct 打数组字段时给的是字段地址（减对象起点即偏移）；标量给的是值——对象先按字节填花纹（第 k 遍每字节填偏移的第 k 个字节），
//   读回值的最低字节就是偏移的第 k 个字节，三遍拼出 24 位偏移。布尔值只给 0 / 1，偏移按「紧跟前一字段」补；位域连成一段按原样字节处理；
//   成员偏移重叠的嵌套记录是联合，整段按原样字节处理。提取完自检（按偏移有序、不重叠、不出界），不过就标「布局不明」，这个结构只能照旧拒绝
enum { SL_REC = 0, SL_SINT, SL_UINT, SL_FLT, SL_PTR, SL_RAW };
typedef struct { char path[128]; char type[64]; uint32_t off, size, end; uint16_t width; uint8_t kind, known, bits, approx; } snap_fld;
typedef struct snap_lay { uint32_t size, n, cap; int bad; snap_fld *f; char why[96]; } snap_lay;   // why：布局不明的原因（第一处）
typedef struct { uint64_t fp; const snap_lay *lay; uint32_t magic; } snap_fp;   // magic：住在游戏内存里、首字段是 magic 的对象填它的值（布局变了按它在恢复的内存里找对象原地转），其余 0
typedef void (*snap_fp_cb)(const char *name, snap_fp fp);

static __attribute__((unused)) struct { snap_lay *L; uintptr_t base; int pass, depth; uint32_t idx; uint32_t open[8]; char pre[8][128]; } g_sl;
#define SL_BAD(L, ...) do { if (!(L)->bad) snprintf((L)->why, sizeof (L)->why, __VA_ARGS__); (L)->bad = 1; } while (0)
static __attribute__((unused)) snap_fld *sl_next(void) {
    snap_lay *L = g_sl.L;
    if (g_sl.idx == L->n) {
        if (g_sl.pass) { SL_BAD(L, "第 %d 遍字段比第一遍多", g_sl.pass + 1); return NULL; }
        if (L->n == L->cap) { uint32_t c = L->cap ? L->cap * 2 : 64; snap_fld *f = (snap_fld *)realloc(L->f, sizeof *f * c); if (!f) { SL_BAD(L, "内存不够"); return NULL; } L->f = f; L->cap = c; }
        memset(&L->f[L->n], 0, sizeof L->f[0]); L->n++;
    }
    return &L->f[g_sl.idx++];
}
static __attribute__((unused)) uint32_t sl_scalar_size(const char *t) {
    static const char *const s1[] = {"char", "signed char", "unsigned char", "int8_t", "uint8_t", "_Bool", "bool"}, *const s2[] = {"short", "unsigned short", "int16_t", "uint16_t"},
        *const s4[] = {"int", "unsigned int", "int32_t", "uint32_t", "float"},
        *const s8[] = {"long", "unsigned long", "long long", "unsigned long long", "int64_t", "uint64_t", "size_t", "ssize_t", "uintptr_t", "intptr_t", "double"};
    size_t n = strlen(t); if (n && t[n - 1] == '*') return sizeof(void *);
    for (size_t i = 0; i < sizeof s1 / sizeof *s1; i++) if (!strcmp(t, s1[i])) return 1;
    for (size_t i = 0; i < sizeof s2 / sizeof *s2; i++) if (!strcmp(t, s2[i])) return 2;
    for (size_t i = 0; i < sizeof s4 / sizeof *s4; i++) if (!strcmp(t, s4[i])) return 4;
    for (size_t i = 0; i < sizeof s8 / sizeof *s8; i++) if (!strcmp(t, s8[i])) return 8;
    return 0;
}
static __attribute__((unused)) int sl_printf(const char *fmt, ...) {
    snap_lay *L = g_sl.L; if (L->bad) return 0;
    va_list ap; va_start(ap, fmt);
    if (!strcmp(fmt, "%s") || !strcmp(fmt, " {\n") || !strcmp(fmt, "}\n")) { va_end(ap); return 0; }   // 顶层类型名、记录开头、顶层收尾
    if (!strncmp(fmt, "%s}", 3)) {   // 嵌套记录收尾
        if (g_sl.depth > 0) { g_sl.depth--; if (!g_sl.pass) L->f[g_sl.open[g_sl.depth]].end = g_sl.idx; }
        va_end(ap); return 0; }
    if (strncmp(fmt, "%s%s %s ", 8)) { va_end(ap); SL_BAD(L, "认不出的格式串 %.40s", fmt); return 0; }
    (void)va_arg(ap, const char *); const char *type = va_arg(ap, const char *), *name = va_arg(ap, const char *);
    snap_fld *f = sl_next(); if (!f) { va_end(ap); return 0; }
    if (!g_sl.pass) {
        int k = 0; f->path[0] = 0;
        for (int d = 0; d < g_sl.depth; d++) k += snprintf(f->path + k, sizeof f->path - (size_t)k > 0 ? sizeof f->path - (size_t)k : 0, "%s.", g_sl.pre[d]);
        snprintf(f->path + (k < (int)sizeof f->path ? k : (int)sizeof f->path - 1), sizeof f->path - (size_t)(k < (int)sizeof f->path ? k : (int)sizeof f->path - 1), "%s", name);
        snprintf(f->type, sizeof f->type, "%s", !strcmp(type, "_Bool") ? "bool" : type);   // 同一个布尔字段编译器有时打 _Bool 有时打 bool
        if (strlen(type) >= sizeof f->type || k >= (int)sizeof f->path - 1) SL_BAD(L, "名字太长：%.40s %.40s", type, name);   // 截断了的名字不能拿来对字段
    }
    const char *rest = fmt + 8;
    if (!strcmp(rest, "=")) {   // 嵌套记录开头（格式串不带换行，后面紧跟一行 " {"）：子字段带上这一级的名字
        if (g_sl.depth >= 8) { SL_BAD(L, "嵌套超过 8 层：%.40s", name); va_end(ap); return 0; }
        if (!g_sl.pass) { f->kind = SL_REC; g_sl.open[g_sl.depth] = g_sl.idx - 1; }
        snprintf(g_sl.pre[g_sl.depth], sizeof g_sl.pre[0], "%s", name); g_sl.depth++;
        va_end(ap); return 0; }
    if (!strcmp(rest, "= *%p\n")) {   // 给的是字段地址：数组、ObjC 对象引用（id / Class / NSFoo *）、_Atomic(T)、__fp16、__int128
        uintptr_t p = (uintptr_t)va_arg(ap, void *);
        if (!g_sl.pass) { f->kind = SL_RAW; f->known = 1; f->off = (uint32_t)(p - g_sl.base);
            char base[64]; snprintf(base, sizeof base, "%s", type); char *b = strchr(base, '['); uint64_t cnt = 1; const char *q = strchr(type, '[');
            if (b) { *b = 0; while (b > base && b[-1] == ' ') *--b = 0; }
            while (q && *q == '[') { cnt *= strtoull(q + 1, NULL, 10); q = strchr(q, ']'); q = q ? q + 1 : NULL; }
            uint32_t es = sl_scalar_size(base);
            if (!es && (!strncmp(base, "id", 2) && (base[2] == 0 || base[2] == '<' || base[2] == ' ')) ) es = sizeof(void *);
            if (!es && !strncmp(base, "Class", 5)) es = sizeof(void *);
            if (!es && !strncmp(base, "_Atomic(", 8)) { char in[64]; snprintf(in, sizeof in, "%s", base + 8); char *e = strrchr(in, ')'); if (e) *e = 0; es = sl_scalar_size(in); }
            if (!es && !strcmp(base, "__fp16")) es = 2;
            if (!es && strstr(base, "__int128")) es = 16;
            if (es) { f->size = (uint32_t)(es * cnt); if (!b && (base[strlen(base) - 1] == '*' || !strncmp(base, "id", 2) || !strncmp(base, "Class", 5))) f->kind = SL_PTR; } else f->approx = 1; }
        va_end(ap); return 0; }
    if (!strncmp(rest, ": %zu = ", 8)) {   // 位域
        size_t w = va_arg(ap, size_t); if (!g_sl.pass) { f->bits = 1; f->width = (uint16_t)w; f->kind = SL_RAW; }
        va_end(ap); return 0; }
    if (strncmp(rest, "= ", 2)) { SL_BAD(L, "认不出的格式串 %.40s", fmt); va_end(ap); return 0; }
    const char *c = strchr(rest, '%'); if (!c) { SL_BAD(L, "认不出的格式串 %.40s", fmt); va_end(ap); return 0; }
    c++; int lm = 0; while (*c == 'l' || *c == 'h' || *c == 'z' || *c == 'j' || *c == 't' || *c == '.' || (*c >= '0' && *c <= '9')) { if (*c == 'h') lm -= 1; else if (*c == 'l' || *c == 'z' || *c == 'j' || *c == 't') lm = 2; c++; }
    if (!strchr("spfgeadiuxXoc", *c) || !*c) { va_end(ap); if (!g_sl.pass) { f->kind = SL_RAW; f->known = 0; } return 0; }   // 向量（%v4hlf）、long double（%Lf）等：值读不了，偏移按前后锚点补
    uint64_t v = 0; uint32_t sz = 0; uint8_t kind = 0;
    if (*c == 's') { v = (uintptr_t)va_arg(ap, const char *); sz = sizeof(void *); kind = SL_PTR; }   // 字符串指针：只要指针值，不读内容
    else if (*c == 'p') { v = (uintptr_t)va_arg(ap, void *); sz = sizeof(void *); kind = SL_PTR; }
    else if (*c == 'f' || *c == 'g' || *c == 'e' || *c == 'a') { double d = va_arg(ap, double); kind = SL_FLT;
        // float 还是 double：都打 %f。typedef（GLfloat 等）看不出，第一遍按值判——float 字段提升成 double 是精确的，转回 float 再提升按位不变；
        //   double 字段装着花纹（逐字节递增）尾数低位非零，过不了这一来回。之后几遍用第一遍定下的长度
        int is4 = !strcmp(type, "float") ? 1 : !strcmp(type, "double") ? 0 : -1;
        if (is4 < 0) { if (g_sl.pass) is4 = f->size == 4; else { float x = (float)d; double back = x; is4 = !memcmp(&back, &d, 8); } }
        if (is4) { float x = (float)d; uint32_t u; memcpy(&u, &x, 4); v = u; sz = 4; } else { memcpy(&v, &d, 8); sz = 8; } }
    else { v = (uint64_t)va_arg(ap, long long); kind = (*c == 'd' || *c == 'i') ? SL_SINT : SL_UINT; sz = lm == -2 ? 1 : lm == -1 ? 2 : lm == 2 ? 8 : *c == 'c' ? 1 : 4; }
    va_end(ap);
    int boolean = !strcmp(type, "_Bool") || !strcmp(type, "bool");
    if (!g_sl.pass) { f->kind = boolean ? SL_RAW : kind; f->size = boolean ? 1 : sz; f->known = !boolean; }
    if (!boolean) f->off |= (uint32_t)(v & 0xff) << (8 * g_sl.pass);
    return 0;
}
static __attribute__((unused)) int sl_off_cmp(const void *a, const void *b) { const snap_fld *x = (const snap_fld *)a, *y = (const snap_fld *)b; return x->off < y->off ? -1 : x->off > y->off; }
// 三遍取完后整理：偏移不明的字段并段、联合并段、去掉记录标记、补数组长度、自检
//   锚点 = 偏移已知的字段（标量按花纹、数组 / 对象引用按地址）。连着的一串偏移不明的字段（布尔只给 0 / 1、位域、向量、long double 等）并成一段原样字节：
//   从前一锚点末尾到下一锚点开头（含填充）；前一锚点是长度不明的数组时连它一起并（分不出界）。段的类型名带这串字段的名字 / 类型 / 位宽哈希
static __attribute__((unused)) void sl_finish(snap_lay *L, uint32_t size) {
    L->size = size; if (L->bad) return;
#define SL_LEAF(k) (L->f[k].kind != SL_REC && L->f[k].kind != 0xff)
    for (uint32_t i = 0; i < L->n; i++) {
        if (!SL_LEAF(i) || L->f[i].known) continue;
        uint32_t j = i, cnt = 0; uint64_t h = 1469598103934665603ull;
        for (; j < L->n; j++) { if (!SL_LEAF(j)) continue; if (L->f[j].known) break; cnt++;
            for (const char *t = L->f[j].path; *t; t++) h = (h ^ (uint8_t)*t) * 0x100000001b3ull;
            for (const char *t = L->f[j].type; *t; t++) h = (h ^ (uint8_t)*t) * 0x100000001b3ull; h = (h ^ L->f[j].width) * 0x100000001b3ull; }
        int p = (int)i - 1; while (p >= 0 && !SL_LEAF(p)) p--;
        uint32_t hi = j < L->n ? L->f[j].off : size;
        snap_fld *keep = &L->f[i]; uint32_t lo;
        if (p >= 0 && L->f[p].approx) {   // 前一锚点长度不明：连它一起并
            snap_fld *a = &L->f[p]; for (const char *t = a->type; *t; t++) h = (h ^ (uint8_t)*t) * 0x100000001b3ull;
            char t2[64]; snprintf(t2, sizeof t2, "%.30s+seg#%016llx", a->type, (unsigned long long)h); snprintf(a->type, sizeof a->type, "%s", t2);
            a->approx = 0; a->size = hi > a->off ? hi - a->off : 0; a->kind = SL_RAW;
            for (uint32_t k = i; k < j; k++) if (SL_LEAF(k)) { L->f[k].kind = 0xff; L->f[k].bits = 0; }
            i = j ? j - 1 : 0; continue; }
        lo = p < 0 ? 0 : L->f[p].off + L->f[p].size;
        if (cnt > 1 || keep->bits) { char t2[64]; snprintf(t2, sizeof t2, "seg#%016llx", (unsigned long long)h); snprintf(keep->type, sizeof keep->type, "%s", t2); }
        keep->kind = SL_RAW; keep->known = 1; keep->bits = 0; keep->off = lo; keep->size = hi > lo ? hi - lo : 0;
        for (uint32_t k = i + 1; k < j; k++) if (SL_LEAF(k)) { L->f[k].kind = 0xff; L->f[k].bits = 0; }
        i = j ? j - 1 : 0;
    }
#undef SL_LEAF
    for (uint32_t i = 0; i < L->n; i++) {   // 联合：子字段偏移重叠的记录整段并成原样字节（内容描述哈希进类型名）
        snap_fld *r = &L->f[i]; if (r->kind != SL_REC) continue;
        uint32_t lo = UINT32_MAX, hi = 0, prev_end = 0; int over = 0, first = 1; uint64_t h = 1469598103934665603ull;
        for (uint32_t k = i + 1; k < r->end && k < L->n; k++) { snap_fld *c = &L->f[k]; if (c->kind == SL_REC || c->kind == 0xff) continue;
            if (!first && c->off < prev_end) over = 1; first = 0;
            if (c->off < lo) lo = c->off; uint32_t e = c->off + (c->approx ? 0 : c->size); if (e > hi) hi = e; if (e > prev_end) prev_end = e;
            for (const char *s = c->path; *s; s++) h = (h ^ (uint8_t)*s) * 0x100000001b3ull; for (const char *s = c->type; *s; s++) h = (h ^ (uint8_t)*s) * 0x100000001b3ull; }
        if (!over) continue;
        char t[64]; snprintf(t, sizeof t, "%.40s#%016llx", r->type, (unsigned long long)h); snprintf(r->type, sizeof r->type, "%s", t);
        r->kind = SL_RAW; r->known = 1; r->off = lo; r->size = hi - lo;
        for (uint32_t k = i + 1; k < r->end && k < L->n; k++) L->f[k].kind = 0xff;
    }
    uint32_t w = 0; for (uint32_t i = 0; i < L->n; i++) if (L->f[i].kind != SL_REC && L->f[i].kind != 0xff) L->f[w++] = L->f[i];
    L->n = w; qsort(L->f, L->n, sizeof *L->f, sl_off_cmp);
    for (uint32_t i = 0; i < L->n; i++) {   // 元素类型不明的数组：长度到下一字段（含尾部填充）
        snap_fld *f = &L->f[i]; if (!f->approx) continue; uint32_t nx = i + 1 < L->n ? L->f[i + 1].off : size; f->size = nx > f->off ? nx - f->off : 0; }
    for (uint32_t i = 0; i < L->n; i++) { snap_fld *f = &L->f[i];   // 自检
        if (f->off + f->size > size) { SL_BAD(L, "字段 %.40s 出界（%u+%u > %u）", f->path, f->off, f->size, size); return; }
        if (i && f->off < L->f[i - 1].off + L->f[i - 1].size) { SL_BAD(L, "字段 %.30s 与 %.30s 重叠（%u < %u+%u）", f->path, L->f[i - 1].path, f->off, L->f[i - 1].off, L->f[i - 1].size); return; }
        if (!f->size && f->kind != SL_RAW) { SL_BAD(L, "字段 %.40s 长度为 0", f->path); return; } }
}
static inline void sl_begin(snap_lay *L, void *obj) { memset(L, 0, sizeof *L); g_sl.L = L; g_sl.base = (uintptr_t)obj; }
static inline void sl_pass(snap_lay *L, void *obj, uint32_t size, int pass) {
    if (pass && g_sl.idx != L->n) SL_BAD(L, "第 %d 遍字段数 %u 与第一遍 %u 不同", pass, g_sl.idx, L->n);   // 每遍字段序列必须一样
    uint8_t *b = (uint8_t *)obj; for (uint32_t i = 0; i < size; i++) b[i] = (uint8_t)(i >> (8 * pass));
    g_sl.pass = pass; g_sl.idx = 0; g_sl.depth = 0;
}
// 取类型 T 的布局进 *Lp（对一个专用静态对象填花纹，不碰真对象；取完清零）
#define SNAP_LAY_TYPE_(T, Lp) do { static T sl_o_; sl_begin((Lp), &sl_o_); \
        for (int sl_p_ = 0; sl_p_ < 3 && !(Lp)->bad; sl_p_++) { sl_pass((Lp), &sl_o_, (uint32_t)sizeof sl_o_, sl_p_); __builtin_dump_struct(&sl_o_, sl_printf); } \
        if (g_sl.idx != (Lp)->n) SL_BAD((Lp), "末遍字段数 %u 与第一遍 %u 不同", g_sl.idx, (Lp)->n); sl_finish((Lp), (uint32_t)sizeof sl_o_); memset(&sl_o_, 0, sizeof sl_o_); } while (0)

// 存：每个结构一条 [名长 u16][名][结构长 u32][不明 u8][字段数 u32]{种类 u8 偏移 u32 长度 u32 路径长 u8 路径 类型长 u8 类型}
static inline int snap_lay_write(FILE *f, const char *name, const snap_lay *L) {
    uint16_t nl = (uint16_t)strlen(name); uint8_t bad = L ? (uint8_t)(L->bad != 0) : 1; uint32_t sz = L ? L->size : 0, n = L && !L->bad ? L->n : 0; int e = 0;
    e |= fwrite(&nl, 2, 1, f) != 1 || fwrite(name, 1, nl, f) != nl || fwrite(&sz, 4, 1, f) != 1 || fwrite(&bad, 1, 1, f) != 1 || fwrite(&n, 4, 1, f) != 1;
    for (uint32_t i = 0; i < n && !e; i++) { const snap_fld *x = &L->f[i]; uint8_t pl = (uint8_t)strlen(x->path), tl = (uint8_t)strlen(x->type);
        e |= fwrite(&x->kind, 1, 1, f) != 1 || fwrite(&x->off, 4, 1, f) != 1 || fwrite(&x->size, 4, 1, f) != 1 || fwrite(&pl, 1, 1, f) != 1 || fwrite(x->path, 1, pl, f) != pl
            || fwrite(&tl, 1, 1, f) != 1 || fwrite(x->type, 1, tl, f) != tl; }
    return e ? -1 : 0;
}
// 读一条：成功回 1（name 填名字，L 由调用方 snap_lay_free），文件尾回 0，坏回 -1
static inline int snap_lay_read(FILE *f, char *name, size_t ncap, snap_lay *L) {
    uint16_t nl; memset(L, 0, sizeof *L); if (fread(&nl, 2, 1, f) != 1) return 0;
    if (nl >= ncap || fread(name, 1, nl, f) != nl) return -1; name[nl] = 0;
    uint8_t bad; uint32_t n; if (fread(&L->size, 4, 1, f) != 1 || fread(&bad, 1, 1, f) != 1 || fread(&n, 4, 1, f) != 1 || n > (1u << 20)) return -1;
    L->bad = bad; L->f = (snap_fld *)calloc(n ? n : 1, sizeof *L->f); if (!L->f) return -1; L->cap = n;
    for (uint32_t i = 0; i < n; i++) { snap_fld *x = &L->f[i]; uint8_t pl, tl;
        if (fread(&x->kind, 1, 1, f) != 1 || fread(&x->off, 4, 1, f) != 1 || fread(&x->size, 4, 1, f) != 1 || fread(&pl, 1, 1, f) != 1 || pl >= sizeof x->path
            || fread(x->path, 1, pl, f) != pl || fread(&tl, 1, 1, f) != 1 || tl >= sizeof x->type || fread(x->type, 1, tl, f) != tl) return -1;
        x->path[pl] = 0; x->type[tl] = 0; L->n++; }
    return 1;
}
static inline void snap_lay_free(snap_lay *L) { free(L->f); memset(L, 0, sizeof *L); }
static inline const snap_fld *sl_find(const snap_lay *L, const char *path) { for (uint32_t i = 0; i < L->n; i++) if (!strcmp(L->f[i].path, path)) return &L->f[i]; return NULL; }
static inline int sl_is_int(uint8_t k) { return k == SL_SINT || k == SL_UINT; }
// 同一字段两版能不能原样搬：类型名、种类相同且长度相同；原样字节段（元素类型不明的数组只能量到下一字段，含尾部填充）类型名相同、长度差不到 8 字节时
//   差的只是填充，按短的搬。局限（与指纹相同）：数组元素结构内部变了但名字、总长不变时看不出——__builtin_dump_struct 不展开数组元素
static inline int sl_same(const snap_fld *x, const snap_fld *n) {
    if (strcmp(x->type, n->type) || x->kind != n->kind) return 0;
    if (x->size == n->size) return 1;
    return x->kind == SL_RAW && (x->size > n->size ? x->size - n->size : n->size - x->size) < 8;
}
// 转换计划：旧布局 o → 本版 c。能转回 0，st = {原样搬, 按值换宽度 / 精度, 新加取缺省, 旧有新无丢掉}；不能回 -1，why 写第一个接不上的字段
static inline int snap_lay_plan(const snap_lay *o, const snap_lay *c, uint32_t st[4], char *why, size_t wn) {
    memset(st, 0, 4 * sizeof *st);
    if (!o || !c || o->bad || c->bad) { snprintf(why, wn, "%s布局不明", !o || o->bad ? "快照里的" : "本版的"); return -1; }
    for (uint32_t i = 0; i < c->n; i++) { const snap_fld *n = &c->f[i], *x = sl_find(o, n->path);
        if (!x) { st[2]++; continue; }
        if (sl_same(x, n)) st[0]++;
        else if ((sl_is_int(x->kind) && sl_is_int(n->kind)) || (x->kind == SL_FLT && n->kind == SL_FLT)) st[1]++;
        else { snprintf(why, wn, "字段 %s 从 %s（%u 字节）变成 %s（%u 字节）", n->path, x->type, x->size, n->type, n->size); return -1; } }
    for (uint32_t i = 0; i < o->n; i++) if (!sl_find(c, o->f[i].path)) st[3]++;
    return 0;
}
// 搬一个对象：dst 由调用方先放本版缺省（一般全 0）；回有损字段数（整数换窄放不下），>0 时调用方应拒绝
static inline int snap_lay_apply(const snap_lay *o, const void *src, const snap_lay *c, void *dst) {
    int lossy = 0; const uint8_t *s = (const uint8_t *)src; uint8_t *d = (uint8_t *)dst;
    for (uint32_t i = 0; i < c->n; i++) { const snap_fld *n = &c->f[i], *x = sl_find(o, n->path); if (!x) continue;
        if (sl_same(x, n)) { memcpy(d + n->off, s + x->off, x->size < n->size ? x->size : n->size); continue; }
        if (x->kind == SL_FLT) { double v; if (x->size == 4) { float t; memcpy(&t, s + x->off, 4); v = t; } else memcpy(&v, s + x->off, 8);
            if (n->size == 4) { float t = (float)v; memcpy(d + n->off, &t, 4); } else memcpy(d + n->off, &v, 8); continue; }
        uint64_t u = 0; memcpy(&u, s + x->off, x->size > 8 ? 8 : x->size); int neg = 0;
        if (x->kind == SL_SINT && x->size < 8 && (u >> (8 * x->size - 1)) & 1) { u |= ~0ull << (8 * x->size); neg = 1; } else if (x->kind == SL_SINT && x->size == 8) neg = (int64_t)u < 0;
        uint32_t ns = n->size > 8 ? 8 : n->size;
        if (n->kind == SL_UINT) { if (neg || (ns < 8 && u >> (8 * ns))) lossy++; }
        else if (ns < 8) { int64_t v = (int64_t)u, lo = -(1ll << (8 * ns - 1)), hi = (1ll << (8 * ns - 1)) - 1; if ((!neg && u > (uint64_t)hi) || (neg && v < lo)) lossy++; }
        else if (!neg && x->kind == SL_UINT && (int64_t)u < 0) lossy++;
        memcpy(d + n->off, &u, ns); }
    return lossy;
}

// 布局转换表的一项：快照里的旧布局 o → 本版 c。magic 非零 = 住在游戏内存里、首字段是 magic 的对象（恢复时整片找、原地转）
typedef struct { char name[96]; const snap_lay *o, *c; uint32_t magic; uint64_t nobj, nlossy, ndrop; } snap_conv;
// 转一个对象：dst 先清零（新加字段取缺省 0）再按字段搬；旧有新无且旧值非零的字段计「丢值」。src、dst 不能重叠
static inline void snap_conv_one(snap_conv *e, const void *src, void *dst) {
    memset(dst, 0, e->c->size); int l = snap_lay_apply(e->o, src, e->c, dst);
    for (uint32_t i = 0; i < e->o->n; i++) { const snap_fld *x = &e->o->f[i]; if (x->kind == SL_REC || sl_find(e->c, x->path)) continue;
        const uint8_t *q = (const uint8_t *)src + x->off; for (uint32_t k = 0; k < x->size; k++) if (q[k]) { e->ndrop++; break; } }
    e->nobj++; e->nlossy += (uint64_t)(l > 0 ? l : 0);
}
// 认对象：首 4 字节等于 magic，且旧布局里每个指针字段是 0 或用户态地址（[0x1000, 2^47)）——恰好含这 4 个字符的文本当指针读是 0x20.. 打头，远超用户态地址。
//   旧布局一个指针字段都没有的类型只凭 magic 认会误改游戏数据，调用方不扫（snap_conv_scannable）
static inline uint32_t snap_conv_nptr(const snap_lay *L) { uint32_t n = 0; for (uint32_t k = 0; k < L->n; k++) n += L->f[k].kind == SL_PTR && L->f[k].size == 8; return n; }
static inline const char *snap_conv_scannable(const snap_conv *e) {
    const snap_fld *mo = sl_find(e->o, "magic"), *mc = sl_find(e->c, "magic");
    if (!mo || !mc || mo->off || mc->off || mo->size != 4 || mc->size != 4) return "两版 magic 不都在开头 4 字节";
    if (!snap_conv_nptr(e->o)) return "旧布局没有指针字段，只凭 magic 认对象会误改游戏数据";
    return NULL;
}
static inline int snap_conv_obj_ok(const snap_conv *e, const uint8_t *p) {
    if (*(const uint32_t *)p != e->magic) return 0;
    for (uint32_t i = 0; i < e->o->n; i++) { const snap_fld *x = &e->o->f[i]; if (x->kind != SL_PTR || x->size != 8) continue;
        uint64_t v; memcpy(&v, p + x->off, 8); if (v && (v < 0x1000 || v >> 47)) return 0; }
    return 1;
}
// 在 [lo, lo+n) 里按 8 字节对齐找 ev[0..ne) 的对象原地转；tmp 至少容得下最长的旧布局。转完跳过对象内部；旧比新长时多出的尾巴留在原处（对象的保留区）
static inline void snap_conv_scan(snap_conv *const *ev, int ne, uint8_t *lo, uint64_t n, uint8_t *tmp) {
    uint8_t *end = lo + n, *a = (uint8_t *)(((uintptr_t)lo + 7) & ~(uintptr_t)7);
    for (; a + 4 <= end; a += 8) { uint32_t w; memcpy(&w, a, 4);
        for (int j = 0; j < ne; j++) { snap_conv *e = ev[j]; if (w != e->magic) continue;
            uint32_t span = e->o->size > e->c->size ? e->o->size : e->c->size;
            if ((uint64_t)(end - a) < span || !snap_conv_obj_ok(e, a)) continue;
            memcpy(tmp, a, e->o->size); snap_conv_one(e, tmp, a);
            a += ((e->c->size + 7u) & ~7u) - 8; break; } }
}

// 指纹 + 完整布局：存档记两样，恢复时指纹相同直接用，不同按布局转（见上）。布局每处只取一次
#define SNAP_FP_TYPE(T) ({ static T sfp_z_; static snap_lay sfp_l_; static int sfp_d_; if (!sfp_d_) { SNAP_LAY_TYPE_(T, &sfp_l_); sfp_d_ = 1; } \
        (snap_fp){ SNAP_FP_DUMP_(&sfp_z_), &sfp_l_, 0 }; })
#define SNAP_FP_OF(var) SNAP_FP_TYPE(__typeof__(var))
// 住在游戏内存里的对象（NVN 对象等，游戏给的定长内存原址存放）：带上首字段 magic 的值
#define SNAP_FP_OBJ(T, m) ({ snap_fp sfo_ = SNAP_FP_TYPE(T); sfo_.magic = (m); sfo_; })

// 恢复处读整块结构：布局与快照时相同就是 fread；不同（快照里是旧布局）按旧长度读、逐个按字段转成本版布局，回读到的个数（同 fread）。
//   name 与登记布局指纹的名字相同。图形单测不链宿主时退回 fread
// 弱符号：调 snap_fread 的源文件各自登记「弱链接[<场合>]：s2a_snap_conv_fread」（tools/weak_link_decl.py 只扫 .c / .m）
size_t s2a_snap_conv_fread(void *dst, size_t size, size_t n, FILE *f, const char *name) __attribute__((weak_import));
static inline size_t snap_fread(void *dst, size_t size, size_t n, FILE *f, const char *name) {
    return s2a_snap_conv_fread ? s2a_snap_conv_fread(dst, size, n, f, name) : fread(dst, size, n, f);
}
