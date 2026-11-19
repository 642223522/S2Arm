// 即时存档宿主结构布局提取与跨版本按字段转换（runtime/src/snapfmt.h）：期望值取编译器的 offsetof / sizeof，与被测实现无关
#include "../src/snapfmt.h"
#include <stddef.h>
#include <stdbool.h>

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

    snap_lay_free(&a); snap_lay_free(&b); snap_lay_free(&r);
    if (g_fail) printf("✗ t_snap_layout：%d 项不符（共 %d 项）\n", g_fail, g_ok + g_fail);
    else printf("✓ t_snap_layout：0 处不符（共 %d 项）\n", g_ok);
    return g_fail ? 1 : 0;
}
