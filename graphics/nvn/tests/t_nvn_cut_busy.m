// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 分段提交在 GPU 还忙时不提交、只留时间戳边界（照上游参考实现（MIT）6121fd75 的 sub_cut / ts_boundary；DM_NVN_CUT_BUSY=0 恢复每段都提交）。
// 期望按语义手写，不由被测实现推出：
//   ① 到了切段点、但前面提交的命令缓冲还没回报（GPU 忙）：不提交（分段计数不变）；GPU 闲下来后的切段照常提交（计数 +1）
//   ② 段边界是一个时刻：前一段的「末」报告 = 后一段的「始」报告（同一个 GPU 时间戳，两次换算到客体时钟容 1 µs），且非 0
//   ③ 先后：段 0 始 ≤ 段 0 末 = 段 1 始 ≤ 段 2 始 ≤ 段 2 末（整次提交的 GPU 结束），全部落在提交前后两次读钟之间
//   ④ DM_NVN_CUT_BUSY=0：GPU 忙也提交（计数 +1）
//   ⑤ 段的绘制数从提交开始算：提交一开始就画进沿用的目标 64 次（中间没有切段点），第一个切段点就该提交（旧代码从第一次切段点才开始数 → 不提交）
//   ⑦ 扣 GPU 空闲缝（照上游 3304d6a0 seg_idle_before）：一次提交里先一段计算 +「始」报告、GPU 闲时切段（这个命令缓冲先提交），宿主再睡 20 ms（GPU 没活），
//      再一段计算 +「末」报告、提交。两段计算各不到 1 ms：缺省（扣缝）始末差 < 10 ms；DM_NVN_GPU_TS=segment_gaps（不扣，第四个子进程）始末差 ≥ 20 ms（宿主睡的那段 GPU 空着）。
//      反证：去掉 rep_ticks 里扣 seg_idle_before 那一行 → 缺省子进程始末差 ≥ 20 ms，⑦ 红
//   ⑥ 编码线程开（iPhone / Mac 缺省，DM_NVN_ENC_THREAD=1）同样走 ①②③：计数器堆的时间戳经录制流在编码线程上写（nvn_rec.h RO_R_TS / RO_C_TS）。
//      旧代码编码线程开时不建计数器堆（ts_on 要求 !rec_on()），「忙就只留边界」进不去，每 64 笔真提交一次（照上游 3304d6a0）→ ① 红
// 「GPU 忙」用在途计数 g_seg_inflight 直接置 1 模拟（真实在途的命令缓冲回报时间不可控）；其余都是真 Metal 4 设备、真提交、真时间戳。
// 反证：去掉 sub_cut 里「忙就只留边界」那段 → ① 红（忙时也提交 1 次、只留边界 0 个）；② ③ 照绿（提交的切段点同样记边界时间戳）
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static prog_t pg; static uint8_t *pool_mem; static uint64_t rep[8][2];
static void work(void) {   // one compute dispatch: an encoder of the main command buffer (it writes the pending boundary timestamp at its start)
    S.cprog=&pg; S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)pool_mem,.size=4096}; args_dirty_all();
    p_dispatch d={.x=64,.y=1,.z=1}; dispatch(&d);
}
static void reach_cut(void) { g_stat_draw+=64; sub_cut(); }   // as many draws as DM_NVN_CUT (64) since the last cut, between passes
// 报告的时钟是客体时钟（19.2 MHz，gpu_ticks 同一个）；一个 GPU 时间戳每次换算各取一对 CPU / GPU 采样，同一时刻两次换算差几个滴答（实测 1），判「同一时刻」容 1 µs = 19 个滴答
enum { JIT = 19 };
static int le(uint64_t a, uint64_t b) { return a <= b + JIT; }

static uint64_t idle_gap_diff(void) {   // ⑦：始末两份报告之间夹一次提交 + 宿主睡 20 ms，返回末 − 始（19.2 MHz 滴答）
    for (int i=0;i<200 && atomic_load(&g_seg_inflight);i++) usleep(10000);
    REQUIRE(!atomic_load(&g_seg_inflight));
    nvn_be_sub_begin();
    work(); mtl_sub_counter((uint64_t)(uintptr_t)rep[5],0x10);
    reach_cut();   // GPU 闲：这个命令缓冲提交
    usleep(20000);   // 宿主「翻译」20 ms：GPU 跑完上一个命令缓冲后空着
    work(); mtl_sub_counter((uint64_t)(uintptr_t)rep[6],0);
    uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    for (int i=0;i<200 && !rep[6][1];i++) usleep(10000);
    REQUIRE(rep[5][1] && rep[6][1] && rep[6][1]>=rep[5][1]);
    return rep[6][1]-rep[5][1];
}
static int child(int mode) {   // 1 缺省（编码线程关）、2 缺省 + 编码线程开、0 DM_NVN_CUT_BUSY=0、3 DM_NVN_GPU_TS=segment_gaps（只跑 ⑦）
    int busy_on=mode!=0, enc=mode==2;
    alarm(60);
    unsetenv("NXGAL_BE"); setenv("DM_NVN_ENC_THREAD",enc?"1":"0",1); setenv("DM_NVN_GPU_TS",mode==3?"segment_gaps":"segment",1); setenv("DM_NVN_CUT","64",1);
    if (busy_on) unsetenv("DM_NVN_CUT_BUSY"); else setenv("DM_NVN_CUT_BUSY","0",1);
    mtl_init(); REQUIRE(!g_m3); REQUIRE(rec_on()==enc); REQUIRE(seg_ts());
    NSError *e=nil; MTLCompileOptions *o=[MTLCompileOptions new]; o.languageVersion=MTLLanguageVersion2_3;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { device uint *out [[id(0)]]; };\n"
        "kernel void k(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { uint v=p.x; for (uint i=0;i<4096;i++) v=v*1664525u+1013904223u; a.out[p.x]=v; }\n" options:o error:&e];
    if (!lib) fprintf(stderr,"MSL: %s\n",e.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *cs=[NvShader new]; cs->stage=5; cs->fn=[lib newFunctionWithName:@"k"]; REQUIRE(cs->fn);
    cs->ae=[cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len=cs->ae.encodedLength;
    char err[256]=""; REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[ @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES } ] }, &cs->rf, err, sizeof err));
    pg=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; NvProg *np=[NvProg new]; np->sh[5]=cs; serial_put(pg.serial,np);
    REQUIRE(!posix_memalign((void **)&pool_mem,65536,65536)); memset(pool_mem,0,65536); nvn_be_pool_add(pool_mem,65536);   // 活到进程结束：生产池是不拷贝的 MTLBuffer

    if (!busy_on) {   // ④
        nvn_be_sub_begin(); work();
        atomic_fetch_add(&g_seg_inflight,1); uint64_t c0=g_cuts; reach_cut(); atomic_fetch_sub(&g_seg_inflight,1); uint64_t c1=g_cuts;
        work(); uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        CHECK(c1==c0+1,"④ DM_NVN_CUT_BUSY=0、GPU 忙：切段提交 %llu 次（期望 1）",(unsigned long long)(c1-c0));
        { nvn_be_sub_begin(); g_stat_draw+=64; uint64_t k0=g_cuts; sub_cut(); uint64_t k1=g_cuts;   // ⑤ 64 draws into the inherited target, then the first cut point (GPU idle)
          uint64_t f5=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f5,10000000000ull));
          CHECK(k1==k0+1,"⑤ 提交开始后先画 64 次、第一个切段点：提交 %llu 次（期望 1）",(unsigned long long)(k1-k0)); }
        printf("%s t_nvn_cut_busy 子进程（DM_NVN_CUT_BUSY=0）：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures); return failures!=0;
    }
    CHECK(ts_on(),"%s编码线程%s：建了计数器堆（ts_on）",enc?"⑥ ":"",enc?"开":"关"); if (!ts_on()) return 1;
    if (mode==3) { uint64_t d=idle_gap_diff();
        CHECK(d>=20*19200,"⑦ DM_NVN_GPU_TS=segment_gaps（不扣缝）：始末差 %.2f ms（期望 ≥ 20：宿主睡的那段 GPU 空着）",d/19200.0);
        printf("%s t_nvn_cut_busy 子进程（segment_gaps）：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures); return failures!=0; }
    for (int i=0;i<200 && atomic_load(&g_seg_inflight);i++) usleep(10000);   // the warm-up submissions of mtl_init have reported back
    REQUIRE(!atomic_load(&g_seg_inflight));
    uint64_t t_before=gpu_ticks();
    nvn_be_sub_begin();
    work(); mtl_sub_counter((uint64_t)(uintptr_t)rep[0],0x10); mtl_sub_counter((uint64_t)(uintptr_t)rep[1],0);   // segment 0: start, end
    uint64_t c0=g_cuts, b0=g_cut_busy; uint32_t s0=g_seg;
    atomic_fetch_add(&g_seg_inflight,1); reach_cut(); atomic_fetch_sub(&g_seg_inflight,1);   // GPU busy at the cut
    uint64_t c1=g_cuts, b1=g_cut_busy; uint32_t s1=g_seg;
    work(); mtl_sub_counter((uint64_t)(uintptr_t)rep[2],0x10);   // segment 1: start
    reach_cut();   // GPU idle: commits
    uint64_t c2=g_cuts;
    work(); mtl_sub_counter((uint64_t)(uintptr_t)rep[3],0x10); mtl_sub_counter((uint64_t)(uintptr_t)rep[4],0);   // segment 2: start, end
    uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    for (int i=0;i<200 && !rep[4][1];i++) usleep(10000);
    uint64_t t_after=gpu_ticks();
    CHECK(c1==c0 && b1==b0+1 && s1==s0+1,"① GPU 忙的切段点：提交 %llu 次（期望 0）、只留边界 %llu 个（期望 1）、段号 %u→%u（期望 +1）",(unsigned long long)(c1-c0),(unsigned long long)(b1-b0),s0,s1);
    CHECK(c2==c1+1,"① GPU 闲的切段点：提交 %llu 次（期望 1）",(unsigned long long)(c2-c1));
    uint64_t r0=rep[0][1],r1=rep[1][1],r2=rep[2][1],r3=rep[3][1],r4=rep[4][1];
    printf("  报告（19.2 MHz）：段0 始 %llu、段0 末 %llu、段1 始 %llu、段2 始 %llu、段2 末 %llu；提交前 %llu、等完后 %llu\n",(unsigned long long)r0,(unsigned long long)r1,(unsigned long long)r2,(unsigned long long)r3,(unsigned long long)r4,(unsigned long long)t_before,(unsigned long long)t_after);
    CHECK(r1 && le(r1,r2) && le(r2,r1),"② 段 0 末 = 段 1 始（同一边界，容 %d 个滴答换算误差）：%llu / %llu（差 %lld）",JIT,(unsigned long long)r1,(unsigned long long)r2,(long long)(r2-r1));
    CHECK(le(t_before,r0) && le(r0,r1) && le(r2,r3) && le(r3,r4) && le(r4,t_after),"③ 先后（容 %d 个滴答）：提交前 ≤ 段0 始 ≤ 段0 末，段1 始 ≤ 段2 始 ≤ 段2 末 ≤ 等完后",JIT);
    if (mode==1) { uint64_t d=idle_gap_diff();
        CHECK(d<10*19200,"⑦ 缺省（扣缝）：始末差 %.2f ms（期望 < 10：两段计算各不到 1 ms，宿主睡的 20 ms 不算 GPU 时间）",d/19200.0); }
    printf("%s t_nvn_cut_busy 子进程（缺省%s）：%u 项，%u 项失败\n",failures?"✗":"✓",enc?"、编码线程开":"、编码线程关",checks,failures);
    return failures!=0;
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    if (argc==3 && !strcmp(argv[1],"--child")) return child(atoi(argv[2]));
    unsigned bad=0;
    static const char *const modes[4]={"1","2","0","3"};
    for (int m=0; m<4; m++) {
        fflush(NULL); pid_t pid=fork(); REQUIRE(pid>=0);
        if (!pid) { execl(argv[0],argv[0],"--child",modes[m],(char *)NULL); _exit(127); }
        int st=0; pid_t w; do { w=waitpid(pid,&st,0); } while (w<0 && errno==EINTR); REQUIRE(w==pid);
        bad+=!(WIFEXITED(st) && WEXITSTATUS(st)==0);
    }
    printf("%s t_nvn_cut_busy：缺省（编码线程关 / 开）/ DM_NVN_CUT_BUSY=0 / segment_gaps 四个子进程，%u 个不过（分段提交 GPU 忙时只留时间戳边界；报告扣 GPU 空闲缝）\n",bad?"✗":"✓",bad);
    return bad!=0;
} }
