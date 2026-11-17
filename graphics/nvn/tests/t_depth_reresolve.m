// 游戏中途改深度模式（nvnDeviceSetDepthMode）后，改之前解析好的程序要按新约定重解（#790 D-6XQT：建了约 157 个顶点着色器后才设 near=0，
//   旧程序的顶点着色器仍按 GL 约定改写 z，人物和地形整片落到深度范围外）。含生产 nvn_mtl.m 源码（同 t_link_restart.m 写法）。期望按语义手写：
//   ① 普通程序：深度模式不变时同一个程序两次取到同一个解析结果；模式改了之后再取 → 换成新的解析结果，按序号也查到新的
//   ② 预看（prog_peek）不把旧模式下的解析结果当成已就绪
//   ③ 按阶段分别绑定拼出的合并程序（没有自己的着色器）：模式改了之后重拼——新结果的片元来源仍是片元那个程序（gp），不是被当成空的普通程序重解（那样 gp 会是合并槽自己）
//   夹具里的程序都只带一个按模式 0 载入的顶点着色器（本测不建真着色器库：重解出的新程序没有着色器，只核它不再是带旧约定着色器的那个）
//   负对照：旧实现 ①③ 取到的还是旧对象、② 预看返回旧对象
#ifndef DEPTH_RERESOLVE_SOURCE
#define DEPTH_RERESOLVE_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include DEPTH_RERESOLVE_SOURCE

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

int main(void) { @autoreleasepool {
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    mtl_init(); state_reset(); nvn_be_set_depth_zero(0);
    static prog_t p, v, f;
    p.magic = v.magic = f.magic = MAGIC('P','R','O','G');
    p.serial = nvn_new_serial(); v.serial = nvn_new_serial(); f.serial = nvn_new_serial();
    // 夹具：p、v 各有一个在 near=-w（模式 0）下载入的顶点着色器（load_depth_zero = 0），按序号放进程序表，同 prog_get 解析出的样子
    NvShader *vs0 = [NvShader new]; vs0->load_depth_zero = 0; vs0->stage = 0;
    { NvProg *pp = [NvProg new]; pp->sh[0] = vs0; pp->gp = &p; serial_put(p.serial, pp); }
    { NvProg *vp = [NvProg new]; vp->sh[0] = vs0; vp->gp = &v; serial_put(v.serial, vp); }
    // ①
    NvProg *a = prog_get(&p), *a2 = prog_get(&p);
    CHECK(a && a == a2, "① 模式没变：同一个程序两次取到同一个解析结果（%p / %p）", (__bridge void *)a, (__bridge void *)a2);
    // ③ 先拼好合并程序（顶点来自 v、片元来自 f）
    bind_stages(&v, 1); const prog_t *c = bind_stages(&f, 2);
    NvProg *ca = c ? prog_get(c) : nil;
    CHECK(c && c != &v && c != &f && ca && ca->gp == &f && ca->sh[0] == vs0, "③ 造：按阶段绑定拼出合并程序，顶点着色器来自 v、片元来源是 f");
    nvn_be_set_depth_zero(1);
    // ②
    NvProg *pk = prog_peek(&p);
    CHECK(pk != a, "② 模式改了：预看不返回旧模式下的解析结果（旧 %p，预看 %p）", (__bridge void *)a, (__bridge void *)pk);
    NvProg *b = prog_get(&p);
    CHECK(b && b != a && b->sh[0] != vs0 && serial_get(p.serial) == b, "① 模式改了：重解成新的（旧 %p 新 %p）、不再带旧约定的顶点着色器、按序号查到新的", (__bridge void *)a, (__bridge void *)b);
    CHECK(prog_get(&p) == b, "① 重解之后再取：不再重解（同一个新结果）");
    NvProg *cb = prog_get(c);
    CHECK(cb && cb != ca && cb->gp == &f && cb->sh[0] != vs0, "③ 合并程序模式改了：重拼成新的（旧 %p 新 %p）、片元来源仍是 f（实为 %s）", (__bridge void *)ca, (__bridge void *)cb,
          !cb ? "空" : cb->gp == &f ? "f" : cb->gp == c ? "合并槽自己" : "别的");
    printf("%s t_depth_reresolve：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
