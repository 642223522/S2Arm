// 即时存档宿主结构布局提取与跨版本按字段转换（runtime/src/snapfmt.h）：期望值取编译器的 offsetof / sizeof，与被测实现无关
#include "../src/snapfmt.h"
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <simd/simd.h>

static snap_conv *g_test_conv; static const char *g_test_conv_name;   // ⑫：单测自己当「快照引擎」给转换表项
snap_conv *s2a_snap_conv_get(const char *name) { return g_test_conv && g_test_conv_name && !strcmp(name, g_test_conv_name) ? g_test_conv : NULL; }
static int g_fail, g_ok;
#define CHECK(c, ...) do { if (c) g_ok++; else { g_fail++; printf("  不符："); printf(__VA_ARGS__); printf("\n"); } } while (0)

typedef enum { MODE_A, MODE_B } mode_e;
typedef struct { int32_t x; uint8_t y; } inner_t;
typedef union { uint32_t u; float f; } un_t;
// 旧版
typedef struct {
    int16_t hp; bool alive; uint8_t lvl; char *name; inner_t in; un_t un; mode_e mode; float speed; uint16_t tab[3]; inner_t arr[2];
    unsigned f1 : 3; unsigned f2 : 5; uint64_t gone; void *ptr; uint32_t last;
} v1_t;
// 新版：hp 换宽（int16 → int32）、speed 换精度（float → double）、删 gone、加 added、字段换序（last 挪前）、其余不变
typedef struct {
    uint32_t last; int32_t hp; bool alive; uint8_t lvl; char *name; inner_t in; un_t un; mode_e mode; double speed; uint16_t tab[3]; inner_t arr[2];
    unsigned f1 : 3; unsigned f2 : 5; void *ptr; uint64_t added;
} v2_t;
// 不能转：ptr 从指针变整数
typedef struct { int16_t hp; uint64_t ptr; } bad1_t;
typedef struct { int16_t hp; void *ptr; } bad0_t;
// 不能转：联合成员变了
typedef union { uint32_t u; int32_t i; } un2_t;
typedef struct { un_t un; } ua_t;
typedef struct { un2_t un; } ub_t;

static const snap_fld *fld(const snap_lay *L, const char *p) { return sl_find(L, p); }
static void expect_field(const snap_lay *L, const char *p, size_t off, size_t size) {
    const snap_fld *f = fld(L, p);
    CHECK(f && f->off == off && f->size == size, "字段 %s：期望 偏移 %zu 长 %zu → 真结果 %s 偏移 %u 长 %u", p, off, size, f ? "有" : "没有", f ? f->off : 0, f ? f->size : 0);
}

int main(void) {
    printf("① 旧版布局逐字段对 offsetof / sizeof\n");
    snap_lay a; SNAP_LAY_TYPE_(v1_t, &a);
    CHECK(!a.bad && a.size == sizeof(v1_t), "布局可用、结构长 %zu → bad=%d 长 %u", sizeof(v1_t), a.bad, a.size);
    expect_field(&a, "hp", offsetof(v1_t, hp), 2); expect_field(&a, "alive", offsetof(v1_t, alive), 1); expect_field(&a, "lvl", offsetof(v1_t, lvl), 1);
    expect_field(&a, "name", offsetof(v1_t, name), sizeof(char *)); expect_field(&a, "in.x", offsetof(v1_t, in.x), 4); expect_field(&a, "in.y", offsetof(v1_t, in.y), 1);
    expect_field(&a, "un", offsetof(v1_t, un), sizeof(un_t)); expect_field(&a, "mode", offsetof(v1_t, mode), sizeof(mode_e)); expect_field(&a, "speed", offsetof(v1_t, speed), 4);
    expect_field(&a, "tab", offsetof(v1_t, tab), 6); expect_field(&a, "gone", offsetof(v1_t, gone), 8); expect_field(&a, "ptr", offsetof(v1_t, ptr), sizeof(void *));
    expect_field(&a, "last", offsetof(v1_t, last), 4);
    { const snap_fld *f = fld(&a, "arr"); CHECK(f && f->off == offsetof(v1_t, arr) && f->size >= sizeof(inner_t) * 2, "结构数组 arr 偏移 %zu、长至少 %zu", offsetof(v1_t, arr), sizeof(inner_t) * 2); }
    { const snap_fld *f = fld(&a, "arr"); CHECK(f && f->kind == SL_RAW && !fld(&a, "f1") && !fld(&a, "f2") && f->off + f->size == offsetof(v1_t, gone),
        "结构数组后紧跟的位域 f1/f2 与数组并成一段、止于 gone 的偏移 %zu", offsetof(v1_t, gone)); }
    { typedef struct { uint32_t a; unsigned b1 : 4; unsigned b2 : 4; uint32_t c; } bf_t; snap_lay x; SNAP_LAY_TYPE_(bf_t, &x); const snap_fld *f = fld(&x, "b1");
      CHECK(!x.bad && f && f->off == offsetof(bf_t, a) + 4 && f->off + f->size == offsetof(bf_t, c), "标量后的位域单独成段 [%zu, %zu)", offsetof(bf_t, a) + 4, offsetof(bf_t, c)); snap_lay_free(&x); }

    printf("② 布局存读来回一致\n");
    FILE *t = tmpfile(); int we = snap_lay_write(t, "v1", &a); rewind(t);
    char nm[64]; snap_lay r; int rr = snap_lay_read(t, nm, sizeof nm, &r);
    int same = rr == 1 && !we && !strcmp(nm, "v1") && r.n == a.n && r.size == a.size;
    for (uint32_t i = 0; same && i < r.n; i++) same = !strcmp(r.f[i].path, a.f[i].path) && !strcmp(r.f[i].type, a.f[i].type) && r.f[i].off == a.f[i].off && r.f[i].size == a.f[i].size && r.f[i].kind == a.f[i].kind;
    CHECK(same, "读回 %u 个字段与写入一致", a.n); { snap_lay e; CHECK(snap_lay_read(t, nm, sizeof nm, &e) == 0, "再读到文件尾回 0"); snap_lay_free(&e); } fclose(t);

    printf("③ 旧版对象转新版：逐字段值\n");
    snap_lay b; SNAP_LAY_TYPE_(v2_t, &b); uint32_t st[4]; char why[256] = "";
    int pl = snap_lay_plan(&r, &b, st, why, sizeof why);
    CHECK(pl == 0, "能转（%s）", why);
    CHECK(st[1] == 2 && st[2] == 1 && st[3] == 1, "换宽 / 精度 2、新加 1、丢掉 1 → 真结果 %u / %u / %u（原样 %u）", st[1], st[2], st[3], st[0]);
    v1_t o; memset(&o, 0, sizeof o); o.hp = -1234; o.alive = true; o.lvl = 77; o.name = (char *)0x1122334455667788ull; o.in.x = -5; o.in.y = 9; o.un.f = 2.5f; o.mode = MODE_B;
    o.speed = 1.25f; o.tab[0] = 1; o.tab[2] = 0xBEEF; o.arr[1].x = 42; o.f1 = 5; o.f2 = 17; o.gone = 99; o.ptr = &o; o.last = 0xCAFEF00D;
    v2_t n; memset(&n, 0, sizeof n); int lossy = snap_lay_apply(&r, &o, &b, &n);
    CHECK(lossy == 0, "无损 → 有损 %d", lossy);
    CHECK(n.hp == -1234 && n.alive && n.lvl == 77 && n.name == o.name && n.in.x == -5 && n.in.y == 9 && n.un.f == 2.5f && n.mode == MODE_B, "标量 / 嵌套 / 联合 / 枚举照搬");
    CHECK(n.speed == 1.25 && n.tab[2] == 0xBEEF && n.arr[1].x == 42 && n.f1 == 5 && n.f2 == 17 && n.ptr == &o && n.last == 0xCAFEF00D && n.added == 0, "精度、数组、结构数组、位域、指针、换序、新字段取 0");

    printf("④ 整数换窄放不下要点名有损\n");
    { typedef struct { int32_t hp; } w32; typedef struct { int16_t hp; } w16; snap_lay x, y; SNAP_LAY_TYPE_(w32, &x); SNAP_LAY_TYPE_(w16, &y);
      w32 s1 = {70000}; w16 d1 = {0}; w32 s2 = {-300}; w16 d2 = {0};
      CHECK(snap_lay_apply(&x, &s1, &y, &d1) == 1, "70000 → int16 有损 1");
      CHECK(snap_lay_apply(&x, &s2, &y, &d2) == 0 && d2.hp == -300, "-300 → int16 无损 → %d", d2.hp); snap_lay_free(&x); snap_lay_free(&y); }

    printf("⑤ 不能转的要拒绝并点名\n");
    { snap_lay x, y; SNAP_LAY_TYPE_(bad0_t, &x); SNAP_LAY_TYPE_(bad1_t, &y); CHECK(snap_lay_plan(&x, &y, st, why, sizeof why) == -1 && strstr(why, "ptr"), "指针变整数拒绝（%s）", why); snap_lay_free(&x); snap_lay_free(&y); }
    { snap_lay x, y; SNAP_LAY_TYPE_(ua_t, &x); SNAP_LAY_TYPE_(ub_t, &y); CHECK(snap_lay_plan(&x, &y, st, why, sizeof why) == -1 && strstr(why, "un"), "联合成员变了拒绝（%s）", why); snap_lay_free(&x); snap_lay_free(&y); }

    printf("⑥ 指纹宏同时给布局，且不改指纹（同一类型两次相同）\n");
    { snap_fp p1 = SNAP_FP_TYPE(v1_t), p2 = SNAP_FP_TYPE(v1_t), p3 = SNAP_FP_TYPE(v2_t);
      CHECK(p1.fp == p2.fp && p1.fp != p3.fp && p1.lay && !p1.lay->bad && p1.lay->n == a.n, "指纹稳定、新旧不同、布局随带（%u 个字段）", p1.lay ? p1.lay->n : 0); }

    printf("⑧ 浮点 typedef（看不出 float / double）按值判长度\n");
    { typedef float myf; typedef double myd; typedef struct { myf a; myd b; myf c[2]; myf d; uint32_t e; } ft_t; snap_lay x; SNAP_LAY_TYPE_(ft_t, &x);
      CHECK(!x.bad, "布局可用（%s）", x.why);
      expect_field(&x, "a", offsetof(ft_t, a), 4); expect_field(&x, "b", offsetof(ft_t, b), 8); expect_field(&x, "d", offsetof(ft_t, d), 4); expect_field(&x, "e", offsetof(ft_t, e), 4);
      snap_lay_free(&x); }

    printf("⑦ 值读不了 / 只给地址的类型：按锚点补偏移，后面字段照样对得上\n");
    { typedef struct { uint8_t k; simd_float4 v; _Atomic int at; long double ld; inner_t arr[3]; bool flag; uint32_t tail; _Atomic(uint64_t) a64; uint16_t end; } sp_t;
      snap_lay x; SNAP_LAY_TYPE_(sp_t, &x);
      CHECK(!x.bad, "布局可用（bad=%d）", x.bad);
      expect_field(&x, "k", offsetof(sp_t, k), 1); expect_field(&x, "at", offsetof(sp_t, at), 4); expect_field(&x, "tail", offsetof(sp_t, tail), 4);
      expect_field(&x, "a64", offsetof(sp_t, a64), 8); expect_field(&x, "end", offsetof(sp_t, end), 2);
      { const snap_fld *f = fld(&x, "v"); CHECK(f && f->off == offsetof(sp_t, k) + 1 && f->off + f->size == offsetof(sp_t, v) + sizeof(simd_float4), "向量 v 成段并含到 %zu", offsetof(sp_t, v) + sizeof(simd_float4)); }
      { const snap_fld *f = fld(&x, "arr"); CHECK(f && f->off == offsetof(sp_t, arr) && f->off + f->size == offsetof(sp_t, tail) && !fld(&x, "flag"), "不明长度数组 arr 连同后面的布尔并成一段、止于 tail %zu", offsetof(sp_t, tail)); }
      sp_t s1; memset(&s1, 0, sizeof s1); s1.k = 7; s1.v = (simd_float4){1, 2, 3, 4}; s1.at = 5; s1.ld = 1.5L; s1.arr[2].x = 9; s1.flag = true; s1.tail = 11; s1.a64 = 12; s1.end = 13;
      sp_t s2; memset(&s2, 0, sizeof s2); uint32_t st2[4]; char w2[128] = "";
      CHECK(!snap_lay_plan(&x, &x, st2, w2, sizeof w2) && st2[0] == x.n && !snap_lay_apply(&x, &s1, &x, &s2) && !memcmp(&s1, &s2, sizeof s1), "同布局逐字段搬回来逐字节相同（%u 个字段）", x.n);
      snap_lay_free(&x); }

    printf("⑨ 游戏内存里的对象按 magic 原地转：认得出的转、文本 / 坏指针 / 越界 / 不对齐的不动\n");
    { typedef struct { uint32_t magic; void *native; int32_t ntex; uint64_t presents; } o1_t;
      typedef struct { uint32_t magic; int32_t mid; void *native; int32_t ntex; uint64_t presents; int32_t added; } n1_t;   // 中间插字段、尾部加字段
      typedef struct { uint32_t magic, pad; float v[4]; } np_t;   // 没有指针字段：不扫
      const uint32_t M = 'W' | 'I' << 8 | 'N' << 16 | 'D' << 24;
      snap_lay lo, ln, lp; SNAP_LAY_TYPE_(o1_t, &lo); SNAP_LAY_TYPE_(n1_t, &ln); SNAP_LAY_TYPE_(np_t, &lp);
      snap_conv e; memset(&e, 0, sizeof e); e.o = &lo; e.c = &ln; e.magic = M; snap_conv ep = e; ep.o = &lp; ep.c = &lp;
      CHECK(!snap_conv_scannable(&e) && snap_conv_scannable(&ep), "有指针字段的可扫，没有的不扫（%s）", snap_conv_scannable(&ep) ? snap_conv_scannable(&ep) : "可扫");
      static uint64_t mem[512]; uint8_t *m = (uint8_t *)mem; const size_t N = sizeof mem;
      o1_t a1 = {M, (void *)(uintptr_t)0x100004000ull, 3, 77}, a2 = {M, NULL, 2, 5}, bad = {M, (void *)(uintptr_t)0x10, 1, 1};
      memcpy(m + 64, &a1, sizeof a1); memcpy(m + 2048, &a2, sizeof a2); memcpy(m + 1024, &bad, sizeof bad);
      memcpy(m + 512, "WINDOWS TEXT ok!WINDOWS TEXT ok!", 32);           // 首 4 字节恰是 magic 的文本：指针字段读成 0x20.. 打头，不认
      memcpy(m + 1501, &a1, sizeof a1);                                    // 不对齐：不认
      memcpy(m + N - 8, &M, 4);                                            // 对象放不下（越界）：不认
      uint8_t before[sizeof mem]; memcpy(before, m, N); uint8_t tmp[64];
      snap_conv *ev[1] = {&e}; snap_conv_scan(ev, 1, m, N, tmp);
      n1_t r1, r2; memcpy(&r1, m + 64, sizeof r1); memcpy(&r2, m + 2048, sizeof r2);
      CHECK(e.nobj == 2, "转了 2 个 → 真结果 %llu 个", (unsigned long long)e.nobj);
      CHECK(r1.magic == M && r1.mid == 0 && r1.native == a1.native && r1.ntex == 3 && r1.presents == 77 && r1.added == 0,
            "第 1 个按新布局：magic 保留、mid / added 取 0、native %p ntex 3 presents 77 → 真结果 mid %d native %p ntex %d presents %llu added %d", a1.native, r1.mid, r1.native, r1.ntex, (unsigned long long)r1.presents, r1.added);
      CHECK(r2.native == NULL && r2.ntex == 2 && r2.presents == 5, "第 2 个（指针为 0）也转 → ntex %d presents %llu", r2.ntex, (unsigned long long)r2.presents);
      CHECK(!memcmp(m + 512, before + 512, 32) && !memcmp(m + 1024, before + 1024, sizeof bad) && !memcmp(m + 1501, before + 1501, sizeof a1) && !memcmp(m + N - 8, before + N - 8, 8),
            "文本、坏指针、不对齐、越界四处逐字节没动");
      CHECK(e.nlossy == 0 && e.ndrop == 0, "无有损、无丢值 → %llu / %llu", (unsigned long long)e.nlossy, (unsigned long long)e.ndrop);
      // 旧有新无的字段有值计「丢值」：新版删掉 presents
      typedef struct { uint32_t magic; void *native; int32_t ntex; } n2_t; snap_lay l2; SNAP_LAY_TYPE_(n2_t, &l2);
      snap_conv e2; memset(&e2, 0, sizeof e2); e2.o = &lo; e2.c = &l2; e2.magic = M; n2_t r3; snap_conv_one(&e2, &a1, &r3);
      CHECK(e2.ndrop == 1 && r3.ntex == 3 && r3.native == a1.native, "删掉的 presents 旧值 77 非零计丢值 1 → %llu", (unsigned long long)e2.ndrop);
      snap_lay_free(&lo); snap_lay_free(&ln); snap_lay_free(&lp); snap_lay_free(&l2); }

    printf("⑫ 区里原地转（Vulkan 对象区）与字段号记录里的结构数组（GL）：放得下转、放不下不动；没有表项原样读\n");
    { typedef struct { uint32_t a; float b; } g1_t;
      typedef struct { uint32_t a; uint32_t mid; double b; } g2_t;   // 中间插字段、float → double
      snap_lay l1, l2; SNAP_LAY_TYPE_(g1_t, &l1); SNAP_LAY_TYPE_(g2_t, &l2);
      snap_conv e; memset(&e, 0, sizeof e); e.o = &l1; e.c = &l2;
      g1_t src[3] = {{1, 1.5f}, {2, 2.5f}, {3, 3.5f}};
      union { g1_t o[6]; g2_t n[3]; } blk; uint8_t tmp[sizeof src];
      memset(&blk, 0, sizeof blk); memcpy(blk.o, src, sizeof src);
      int r1 = snap_conv_inplace(&e, &blk, 3, sizeof blk.n, tmp);
      CHECK(r1 == 1 && blk.n[0].a == 1 && blk.n[0].mid == 0 && blk.n[0].b == 1.5 && blk.n[2].a == 3 && blk.n[2].b == 3.5,
            "3 个原地转成新布局：a 1/3、mid 0、b 1.5/3.5 → 回 %d，a %u/%u mid %u b %.1f/%.1f", r1, blk.n[0].a, blk.n[2].a, blk.n[0].mid, blk.n[0].b, blk.n[2].b);
      memset(&blk, 0, sizeof blk); memcpy(blk.o, src, sizeof src); uint8_t before[sizeof blk]; memcpy(before, &blk, sizeof blk);
      int r2 = snap_conv_inplace(&e, &blk, 3, sizeof blk.n - 1, tmp);
      CHECK(r2 == 0 && !memcmp(before, &blk, sizeof blk), "块小 1 字节放不下：回 0、逐字节不动 → 回 %d", r2);
      // GL：字段号记录里整块存的 g1_t[2]，按表项转进 g2_t[2]；负对照：名字不在表里 → 原样读（值就错位）
      FILE *t2 = tmpfile(); sfw w = {0}; sfw_sec(&w, t2, "t.sec", 1); sfw_rec(&w); sfw_blob(&w, 7, src, (uint32_t)(2 * sizeof(g1_t))); sfw_end_rec(&w); sfw_end(&w);
      g2_t out[2], raw[2];
      g_test_conv = &e; g_test_conv_name = "t.g";
      rewind(t2); sfr rr = {0}; int okc = !sfr_sec(&rr, t2, "t.sec", 1) && sfr_rec(&rr) == 1 && sfr_into_conv(&rr, 7, out, sizeof out, "t.g", sizeof(g2_t)); sfr_done(&rr);
      rewind(t2); sfr rn = {0}; int okr = !sfr_sec(&rn, t2, "t.sec", 1) && sfr_rec(&rn) == 1 && sfr_into_conv(&rn, 7, raw, sizeof raw, "t.none", sizeof(g2_t)); sfr_done(&rn);
      fclose(t2);
      CHECK(okc && out[0].a == 1 && out[0].b == 1.5 && out[1].a == 2 && out[1].b == 2.5, "按表项转：a 1/2、b 1.5/2.5 → a %u/%u b %.1f/%.1f", out[0].a, out[1].a, out[0].b, out[1].b);
      CHECK(okr && !(raw[0].b == 1.5 && raw[1].a == 2), "负对照：不在表里原样读，值不对（证明上一条靠的是转换）→ b %.3g、第 2 个 a %u", raw[0].b, raw[1].a);
      g_test_conv = NULL;
      snap_lay_free(&l1); snap_lay_free(&l2); }

    snap_lay_free(&a); snap_lay_free(&b); snap_lay_free(&r);
    if (g_fail) printf("✗ t_snap_layout：%d 项不符（共 %d 项）\n", g_fail, g_ok + g_fail);
    else printf("✓ t_snap_layout：0 处不符（共 %d 项）\n", g_ok);
    return g_fail ? 1 : 0;
}
