// 管线在途去重（pso_archive.h par_fl_enter / par_fl_leave）：直接包含生产 nvn_mtl.m，在真 Metal 设备上编计算管线。期望按「同一归档键同时只编一次」手写：
//   ① 一个线程已登记为某键的编者（par_fl_enter 返回 0），另一线程对同键 par_compute → 编者没交差前不返回（300 ms 内不完成）；编者交出管线 X 后它返回的就是 X（同一对象），去重计数 +1
//   ② 编者交差但结果是 nil（编失败）→ 等的线程自己再编，拿到非空管线
//   ③ 不同键不互等：有人在编 k1 时请求 k2，1 秒内返回
//   ④ 反证（负对照用）：没有在途记录时同键两次请求各编各的——去重计数不变
//   有界等待（par_compute_wait，#884：Metal 编译服务对一条计算管线现编一直不返回，提交线程跟着卡死）：建管线换成桩（g_par_compute_impl），期望按「等到上限就走、不重复起编、编完留给下一次」手写：
//   ⑤ 编译不返回、等 200 ms → 1 秒内返回 nil 且 gave_up = 1，建管线调 1 次
//   ⑥ 同键再请求（那份还卡着）→ 50 ms 内返回 nil、gave_up = 1，不再起新编（仍 1 次）
//   ⑦ 卡住的那份终于返回 X → 下一次同键请求直接拿到 X（同一对象），不重编（仍 1 次）
//   ⑧ 晚 50 ms 返回、上限 1 秒 → 照常拿到结果、gave_up = 0
//   慢编译带 MSL 摘要（#065090，msl_note / par_slow_begin）：期望按 DshOutline 的拆分门槛（main0 体 ≥ 8192 行、s2a_outline_ 助手）手写，哈希按 FNV-1a 64 定义逐字节另算：
//   ⑨ main0 体 8202 行、没有助手 → 「over the 8192-line split threshold, not split」、总行数 8203；两个 s2a_outline_ 助手 → 「split into 2 helpers」；体 3 行 → 「under …」
//   ⑩ 编 300 ms、门槛改成 100 ms → 日志「still compiling after 100 ms … MSL: <调用方给的摘要>」，源文件留一份 <键>.slow.metal、内容逐字节相同
//   ⑪ 编得快（门槛内返回）→ 不留源（反证）
//   重译抢跑（v0.4.1，par_compute_wait 的 t_par_race；门槛改 100 ms、有界等待 300 ms、抢跑在途上限 2 秒）：期望按「谁先好用谁、做不了回原上限、都没好到上限才跳过」手写：
//   ⑫ 原编译不返回、抢跑 50 ms 后给出 Y → 约 150 ms 返回 Y（同一对象）、gave_up 0；超过原上限 300 ms 也没跳过的反面看 ⑬
//   ⑬ 原编译不返回、抢跑做不了（nil）→ 回原上限：约 300 ms 跳过（gave_up 1）
//   ⑭ 原编译 30 ms 就好 → 抢跑不起（起抢跑计数不变），拿到原管线
//   ⑮ 原编译不返回、抢跑也卡 3 秒 → 抢跑在途上限 600 ms 到了跳过（gave_up 1，用时 < 1 秒）
//   ⑯ 抢跑先好、原编译之后才好 → 原结果登记给下一次同键请求（g_par_late）：下一次拿到原管线 X，建管线不再调
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static dispatch_semaphore_t g_hang; static _Atomic int g_stub_calls; static id g_stub_ret; static int g_stub_sleep_ms;
static id<MTLComputePipelineState> stub_hang(id<MTLFunction> fn, NSString *key, NSError **e) {   // 卡到 g_hang 放行，再返回 g_stub_ret
    (void)fn; (void)key; (void)e; atomic_fetch_add(&g_stub_calls, 1); dispatch_semaphore_wait(g_hang, DISPATCH_TIME_FOREVER); return g_stub_ret; }
static id<MTLComputePipelineState> stub_slow(id<MTLFunction> fn, NSString *key, NSError **e) {
    (void)fn; (void)key; (void)e; atomic_fetch_add(&g_stub_calls, 1); usleep((useconds_t)g_stub_sleep_ms * 1000); return g_stub_ret; }
static uint64_t fnv(const char *p) { uint64_t h = 1469598103934665603ull; for (; *p; p++) h = (h ^ (uint8_t)*p) * 1099511628211ull; return h; }
static NSString *log_during(void (^b)(void)) {   // 把 fd 2 接到临时文件跑 b，返回这段时间的日志
    NSString *f = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_pso_slow_%d.log", getpid()]];
    fflush(stderr); int save = dup(2), fd = open(f.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0644); dup2(fd, 2); close(fd);
    b(); fflush(stderr); dup2(save, 2); close(save);
    NSString *r = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] ?: @""; unlink(f.fileSystemRepresentation); return r;
}
static double ms_since(uint64_t t0) { return (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6; }
static id ask(id<MTLFunction> fn, NSString *key, dispatch_semaphore_t done) {   // 另起一线程请求，返回 __block 结果的盒子
    NSMutableArray *box = [NSMutableArray array];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ NSError *e = nil; id ps = par_compute(fn, key, &e); @synchronized (box) { [box addObject:ps ?: NSNull.null]; } dispatch_semaphore_signal(done); });
    return box;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }\n" options:nil error:&e];
    REQUIRE(lib); id<MTLFunction> fn = [lib newFunctionWithName:@"k"]; REQUIRE(fn);
    id<MTLComputePipelineState> X = par_compute_(fn, nil, &e); REQUIRE(X);
    // ①
    id got; ParFlight *mine; uint64_t d0 = atomic_load(&g_par_dedup);
    REQUIRE(!par_fl_enter(@"t-k1", &got, &mine) && mine);
    dispatch_semaphore_t done = dispatch_semaphore_create(0); NSMutableArray *box = ask(fn, @"t-k1", done);
    long early = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
    par_fl_leave(@"t-k1", mine, X);
    long late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    VERIFY(early != 0 && late == 0 && box.count == 1 && box[0] == X && atomic_load(&g_par_dedup) == d0 + 1,
           "① 同键在编：300 ms 内没返回（%s）、编者交差后返回同一对象（%s）、去重 +%llu", early ? "是" : "否", box.count && box[0] == X ? "是" : "否", (unsigned long long)(atomic_load(&g_par_dedup) - d0));
    // ②
    d0 = atomic_load(&g_par_dedup); REQUIRE(!par_fl_enter(@"t-k2", &got, &mine) && mine);
    done = dispatch_semaphore_create(0); box = ask(fn, @"t-k2", done);
    usleep(100000); par_fl_leave(@"t-k2", mine, nil);
    late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    VERIFY(late == 0 && box.count == 1 && box[0] != NSNull.null && box[0] != X && atomic_load(&g_par_dedup) == d0 + 1, "② 编者失败：等的线程自己编出非空管线（%s）", late == 0 && box.count && box[0] != NSNull.null ? "是" : "否");
    // ③
    REQUIRE(!par_fl_enter(@"t-k3", &got, &mine) && mine);
    done = dispatch_semaphore_create(0); box = ask(fn, @"t-k4", done);
    late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    par_fl_leave(@"t-k3", mine, X);
    VERIFY(late == 0 && box.count == 1 && box[0] != NSNull.null, "③ 不同键不互等：1 秒内返回（%s）", late == 0 ? "是" : "否");
    // ④
    d0 = atomic_load(&g_par_dedup); id a = par_compute(fn, @"t-k5", &e), b = par_compute(fn, @"t-k5", &e);
    VERIFY(a && b && atomic_load(&g_par_dedup) == d0, "④ 先后两次（无在途）不计去重：各自返回非空（%s），去重 +%llu", a && b ? "是" : "否", (unsigned long long)(atomic_load(&g_par_dedup) - d0));
    // ⑤–⑦
    g_par_compute_impl = stub_hang; g_hang = dispatch_semaphore_create(0); g_stub_ret = X; atomic_store(&g_stub_calls, 0);
    int gu = 0; uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id r5 = par_compute_wait(fn, @"t-h1", &e, 200 * NSEC_PER_MSEC, &gu); double ms5 = ms_since(t0);
    VERIFY(!r5 && gu == 1 && ms5 < 1000 && atomic_load(&g_stub_calls) == 1, "⑤ 编译不返回、上限 200 ms：%.0f ms 后返回 %s、gave_up %d、建管线 %d 次", ms5, r5 ? "非空" : "nil", gu, atomic_load(&g_stub_calls));
    t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); gu = 0;
    id r6 = par_compute_wait(fn, @"t-h1", &e, 200 * NSEC_PER_MSEC, &gu); double ms6 = ms_since(t0);
    VERIFY(!r6 && gu == 1 && ms6 < 50 && atomic_load(&g_stub_calls) == 1, "⑥ 同键再请求（仍卡着）：%.1f ms 返回 %s、gave_up %d、建管线仍 %d 次", ms6, r6 ? "非空" : "nil", gu, atomic_load(&g_stub_calls));
    dispatch_semaphore_signal(g_hang);
    id r7 = nil; gu = 0; for (int i = 0; i < 100 && !r7; i++) { usleep(10000); r7 = par_compute_wait(fn, @"t-h1", &e, 200 * NSEC_PER_MSEC, &gu); }
    VERIFY(r7 == X && atomic_load(&g_stub_calls) == 1, "⑦ 卡住的那份返回后：下一次同键请求拿到同一对象（%s）、建管线仍 %d 次", r7 == X ? "是" : "否", atomic_load(&g_stub_calls));
    // ⑧
    g_par_compute_impl = stub_slow; g_stub_sleep_ms = 50; atomic_store(&g_stub_calls, 0); gu = 7;
    id r8 = par_compute_wait(fn, @"t-h2", &e, 1000 * NSEC_PER_MSEC, &gu);
    VERIFY(r8 == X && gu == 0 && atomic_load(&g_stub_calls) == 1, "⑧ 晚 50 ms、上限 1 秒：拿到结果（%s）、gave_up %d", r8 == X ? "是" : "否", gu);
    // ⑨
    NSMutableString *big = [NSMutableString stringWithString:@"kernel void main0(device uint* o [[buffer(0)]])\n{\n"];
    for (int i = 0; i < 8200; i++) [big appendString:@"    o[0] += 1u;\n"];
    [big appendString:@"}\n"];
    NSString *n9 = msl_note(@"k9_b", big), *want9 = [NSString stringWithFormat:@"k9_b fallback translation, 8203 lines, fnv %016llx, main0 body 8202 lines, over the 8192-line split threshold, not split", (unsigned long long)fnv(big.UTF8String)];
    NSString *sp = @"static __attribute__((noinline)) void s2a_outline_0(thread uint& a)\n{\n    a += 1u;\n}\n\nstatic __attribute__((noinline)) void s2a_outline_1(thread uint& a)\n{\n    a += 2u;\n}\n\nkernel void main0(device uint* o [[buffer(0)]])\n{\n    s2a_outline_0(o[0]);\n    s2a_outline_1(o[0]);\n}\n";
    NSString *n9b = msl_note(@"k9s_b", sp), *n9c = msl_note(@"k9u_b", @"kernel void main0()\n{\n    return;\n}\n");
    VERIFY([n9 isEqualToString:want9] && [n9b hasSuffix:@"main0 body 4 lines, split into 2 helpers"] && [n9c hasSuffix:@"main0 body 3 lines, under the 8192-line split threshold"],
           "⑨ MSL 摘要：%s | %s | %s", n9.UTF8String, n9b.UTF8String, n9c.UTF8String);
    // ⑩
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_pso_slow_%d", getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *src10 = [dir stringByAppendingPathComponent:@"k10_b.metal"], *keep10 = [dir stringByAppendingPathComponent:@"k10_b.slow.metal"];
    REQUIRE([big writeToFile:src10 atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    g_par_slow_ms = 100; g_par_compute_impl = stub_slow; g_stub_sleep_ms = 300;
    NSString *log10 = log_during(^{ NSError *e2 = nil; t_par_msl_note = n9.UTF8String; t_par_msl_src = src10.fileSystemRepresentation;
        (void)par_compute_wait(fn, @"t-s1", &e2, -1, NULL); t_par_msl_note = t_par_msl_src = NULL; usleep(200000); });
    NSData *k10 = [NSData dataWithContentsOfFile:keep10];
    VERIFY([log10 containsString:[NSString stringWithFormat:@"still compiling after 100 ms on thread"]] && [log10 containsString:[@"; MSL: " stringByAppendingString:n9]] && [k10 isEqualToData:[big dataUsingEncoding:NSUTF8StringEncoding]],
           "⑩ 编 300 ms、门槛 100 ms：日志带摘要（%s）、留源 k10_b.slow.metal（%s）", [log10 containsString:@"; MSL: k9_b"] ? "是" : "否", k10 ? "是" : "否");
    // ⑪
    NSString *src11 = [dir stringByAppendingPathComponent:@"k11_b.metal"], *keep11 = [dir stringByAppendingPathComponent:@"k11_b.slow.metal"];
    REQUIRE([big writeToFile:src11 atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    g_stub_sleep_ms = 0; t_par_msl_note = "fast"; t_par_msl_src = src11.fileSystemRepresentation;
    (void)par_compute_wait(fn, @"t-s2", &e, -1, NULL); t_par_msl_note = t_par_msl_src = NULL; usleep(300000);
    VERIFY(![NSFileManager.defaultManager fileExistsAtPath:keep11], "⑪ 门槛内编完：不留源（%s）", [NSFileManager.defaultManager fileExistsAtPath:keep11] ? "留了" : "没留");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    // ⑫–⑯
    id<MTLLibrary> lib2 = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k2(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i + 1; }\n" options:nil error:&e];
    REQUIRE(lib2); id<MTLComputePipelineState> Y = par_compute_([lib2 newFunctionWithName:@"k2"], nil, &e); REQUIRE(Y && Y != X);
    g_par_slow_ms = 100; g_par_race_wait_ns = 2000 * NSEC_PER_MSEC;
    g_par_compute_impl = stub_hang; g_hang = dispatch_semaphore_create(0); g_stub_ret = X;
    ParRace rY = ^id<MTLComputePipelineState>{ usleep(50000); return Y; }, rNil = ^id<MTLComputePipelineState>{ return nil; };
    uint64_t won0 = atomic_load(&g_par_race_won), n0 = atomic_load(&g_par_race_n);
    gu = 7; t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); t_par_race = rY;
    id r12 = par_compute_wait(fn, @"t-r1", &e, 300 * NSEC_PER_MSEC, &gu); double ms12 = ms_since(t0);
    VERIFY(r12 == Y && gu == 0 && ms12 > 140 && ms12 < 290 && atomic_load(&g_par_race_won) == won0 + 1, "⑫ 原编译卡住、抢跑 50 ms 给出：%.0f ms 返回%s、gave_up %d、抢跑赢 +%llu", ms12, r12 == Y ? "抢跑那份" : "别的", gu, (unsigned long long)(atomic_load(&g_par_race_won) - won0));
    gu = 0; t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); t_par_race = rNil;
    id r13 = par_compute_wait(fn, @"t-r2", &e, 300 * NSEC_PER_MSEC, &gu); double ms13 = ms_since(t0);
    VERIFY(!r13 && gu == 1 && ms13 > 290 && ms13 < 600, "⑬ 抢跑做不了：%.0f ms 跳过（gave_up %d）", ms13, gu);
    g_par_compute_impl = stub_slow; g_stub_sleep_ms = 30; n0 = atomic_load(&g_par_race_n); gu = 7; t_par_race = rY;
    id r14 = par_compute_wait(fn, @"t-r3", &e, 300 * NSEC_PER_MSEC, &gu);
    VERIFY(r14 == X && gu == 0 && atomic_load(&g_par_race_n) == n0, "⑭ 原编译 30 ms 就好：拿到原管线（%s）、起抢跑 +%llu", r14 == X ? "是" : "否", (unsigned long long)(atomic_load(&g_par_race_n) - n0));
    g_par_compute_impl = stub_hang; g_par_race_wait_ns = 600 * NSEC_PER_MSEC; gu = 0; t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    t_par_race = ^id<MTLComputePipelineState>{ usleep(3000000); return Y; };
    id r15 = par_compute_wait(fn, @"t-r4", &e, 300 * NSEC_PER_MSEC, &gu); double ms15 = ms_since(t0);
    VERIFY(!r15 && gu == 1 && ms15 > 590 && ms15 < 1000, "⑮ 两边都卡：%.0f ms 跳过（gave_up %d）", ms15, gu);
    // ⑯：⑫ 的原编译（t-r1）放行，结果登记给下一次
    for (int i = 0; i < 4; i++) dispatch_semaphore_signal(g_hang);
    atomic_store(&g_stub_calls, 0); id r16 = nil; gu = 0; t_par_race = nil;
    for (int i = 0; i < 100 && r16 != X; i++) { usleep(10000); r16 = par_compute_wait(fn, @"t-r1", &e, 300 * NSEC_PER_MSEC, &gu); }
    VERIFY(r16 == X && atomic_load(&g_stub_calls) == 0, "⑯ 抢跑赢后原编译好了：下一次同键拿到原管线（%s）、建管线调 %d 次", r16 == X ? "是" : "否", atomic_load(&g_stub_calls));
    t_par_race = nil; g_par_race_wait_ns = 60ll * 1000000000;
    g_par_slow_ms = PAR_SLOW_MS; g_par_compute_impl = par_compute_;
  }
    if (failures) { printf("✗ t_nvn_pso_inflight：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_pso_inflight：%u 项全过（同一归档键同时只编一次：后到的等先到的、拿同一对象；先到的失败自己编；不同键不互等）\n", checks); return 0;
}
