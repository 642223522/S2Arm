// NVN2 任务 / 网格绘制（11-05，时之笛 0400486024DEC000 进 3D 场景用 DrawMeshTasks / DrawMeshTasksIndirect）：直接包含生产 nvn_mtl.m，经 draw()（OP_DRAW 图元 DM_PRIM_MESH_TASKS）
//   走产品的网格绘制路径画到离屏目标、读回像素。着色器是 mk 用 xcrun metal 编好的真库（t_nvn_mesh.metal，形状照「网格着色接口约定」：入口 main0 / main0_z、起始工作组号在 buffer(29)），
//   反射 json 由本测按约定字段写进库目录，经产品的 shader_get → shader_build 载入。片元着色器写白。
// 期望按约定与夹具几何手算，不由被测实现推出（目标 8×4 RGBA8，先清黑；网格工作组画第 c 列整列，列掩码 bit c = 该列 4 个像素全白）：
//   ① 载入：任务 1111… 是 object（线程 32、载荷 4 → 管线按 16 对齐）；网格 2222… 是 mesh 且带任务、3333… 不带；开 near = 0 后网格载入的入口是 main0_z
//   ② 网格上限：max_vertices 300（> Metal 256）的网格着色器载不进来（nil），报红 1 行点名该键
//   ③ 只绑任务 / 网格 / 片元（BindProgram 位 0x40|0x80|0x02 录成 0x1a，hle_nvn.c）的程序不要求顶点阶段：bind_stages 回这个程序本身（改前回 NULL = 「没有程序」，整笔丢）
//   ④ 无任务 DrawMeshTasks(first 2, count 3)：首笔管线在后台建、本笔跳过并计数（等待数 +1、不报红）；建好后再画 → 列 2、3、4 白 = 0x1c
//   ⑤ 有任务 DrawMeshTasks(first 1, count 2)：任务 t = 1、2 各派 2 个网格组，列 2t、2t+1 → 列 2..5 = 0x3c
//   ⑥ 间接：参数位置 CPU 先写 {7, 0}（录制 / 回放若在 CPU 上读会画列 0..6），同一提交里 GPU 拷贝写成 {3, 4} 后再画 → 列 4、5、6 = 0x70；交完后该处 CPU 读到 {3, 4}
//   ⑦ 间接零工作量：GPU 写 {0, 1} → 一列都不画（0x00）、不报红、照样记一笔间接绘制
//   ⑧ 程序没有网格着色器：跳过、报红 1 行（不当普通绘制画）
//   ⑨ 着色器映射表的阶段名（翻译侧 shader_map.tsv 第 3 列写 task / mesh）经 prog_get 的 stage_of 落到宿主阶段 3 / 4（nvn2_stage_host：NVN 阶段 6 / 7 放曲面两阶段的位置），
//      shader_get 按该阶段载入的是 object / mesh 着色器（11-06 时之笛日志每局 20–30 行「shader … (task|mesh) failed to load」：stage_of 不认这两个名字回 -1，库里明明有）
//   ⑫ #1208 GPU 挂死隔离收网格管线：第一次画出进本提交嫌疑；隔离后同一对跳过、报红、写进隔离表
//   ⑩ GPU 没有对象 / 网格管线（g_mesh_ok = 0，MTLGPUFamilyMetal3 以下）：跳过并计数、报红 1 行、不画（不当普通绘制画）
// 校验层（mk 另跑 MTL_DEBUG_LAYER=1 两套后端）：全部项照过、不中止。负对照（11-11 手工）：改前 pso_desc 给网格管线设 vertexFunction = 网格函数，校验层两套后端都 abort rc=134（setVertexFunction 断言）
// 负对照（11-05 手工做，见坑记录）：把 mtk_encode 写进 29 号槽的起始号换成 0 → ④ 0x07、⑤ 0x0f、⑥ 0x07，三项红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *capture(void (^f)(void)) {   // 这一段打到 stderr 的全部行
    char path[] = "/tmp/t_nvn_mesh_XXXXXX"; int fd = mkstemp(path); REQUIRE(fd >= 0);
    fflush(stderr); int saved = dup(2); REQUIRE(saved >= 0); dup2(fd, 2); close(fd);
    f();
    fflush(stderr); dup2(saved, 2); close(saved);
    NSString *out = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil] ?: @"";
    unlink(path); return out;
}
static int red_lines(NSString *text, NSString *needle) {
    int n = 0; for (NSString *l in [text componentsSeparatedByString:@"\n"]) n += [l containsString:@"【红】"] && (!needle || [l containsString:needle]); return n;
}
static void put_json(NSString *dir, NSString *key, NSDictionary *extra) {
    NSMutableDictionary *j = [@{@"route": @"B", @"bindings": @[], @"chain": @DMSH_CHAIN, @"entry": @"main0"} mutableCopy]; [j addEntriesFromDictionary:extra];
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil]; REQUIRE(d);
    NSString *path = [NSString stringWithFormat:@"%@/%@.json", dir, key]; REQUIRE([d writeToFile:path atomically:YES]);
}
static tex_t g_rt;
static void rt_make(void) {
    memset(&g_rt, 0, sizeof g_rt); g_rt.magic = MAGIC('T', 'E', 'X', 0); g_rt.serial = nvn_new_serial();
    g_rt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 4, .depth = 1, .levels = 1};
    nvn_tex_layout(&g_rt.d, &g_rt.L); nvn_be_tex_init(&g_rt); REQUIRE(tex_mtl(&g_rt));
}
static uint64_t g_frame = 1;
static void frame_begin(void) {   // 新的一帧：目标设成 g_rt 并清黑（清除在渲染遍开时落下）
    nvn_be_set_frame(++g_frame); nvn_be_sub_begin(); state_reset();
    const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr clear; p_clear_color color; op_hdr end; } c = {
        .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &g_rt,
        .clear = {OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}, .color = {.index = 0, .mask = 15, .rgba = {0, 0, 0, 1}}, .end = {OP_END, sizeof(op_hdr)} };
    nvn_be_exec((const uint8_t *)&c);
}
// 交掉这一帧、读回目标：列掩码（bit c = 第 c 列 4 个像素全白）；有半白的列或杂色回 -1
static int frame_columns(void) {
    rp_flush(); uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    id<MTLBuffer> rb = [g_dev newBufferWithLength:8 * 4 * 4 options:MTLResourceStorageModeShared]; REQUIRE(rb);
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex_mtl(&g_rt) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 4, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:128];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const uint8_t *px = rb.contents; int mask = 0;
    for (int c = 0; c < 8; c++) { int white = 0;
        for (int r = 0; r < 4; r++) { const uint8_t *p = px + 32 * r + 4 * c; if (p[0] == 255 && p[1] == 255 && p[2] == 255) white++; else if (p[0] || p[1] || p[2]) return -1; }
        if (white == 4) mask |= 1 << c; else if (white) return -1; }
    return mask;
}
// 一笔网格绘制；管线还在后台建（本笔跳过、等待数 +1）就等建好再画一次。*waited = 本笔是否先跳过过
static void mesh_draw(const p_draw *dw, int *waited) {
    uint64_t w0 = g_mtk_wait; draw(dw, NULL);
    *waited = g_mtk_wait != w0;
    if (*waited) { dispatch_group_wait(g_mtk_group, DISPATCH_TIME_FOREVER); draw(dw, NULL); }
}

int main(void) {
    @autoreleasepool {
        const char *libdir = getenv("T_MESH_LIB"); REQUIRE(libdir);   // mk 编好的 <键>_b.metallib 所在目录；json 由本测写
        setenv("DM_PRESENT_LINK", "0", 1);
        // 本测自己的目录：pso_user.tsv 旁边还有 GPU 挂死隔离表 gpu_quarantine.tsv（⑫ 写它；放共用 /tmp 会被下一局 / 别的单测读到）
        char pdir[] = "/tmp/t_nvn_mesh_XXXXXX"; REQUIRE(mkdtemp(pdir)); char pso_user[sizeof pdir + 16]; snprintf(pso_user, sizeof pso_user, "%s/pso_user.tsv", pdir);
        { int pfd = open(pso_user, O_CREAT | O_WRONLY, 0644); REQUIRE(pfd >= 0); close(pfd); } setenv("DM_PSO_USER", pso_user, 1);   // ④c：本测记下的网格管线行
        mtl_init(); g_msl_dir = @(libdir);
        printf("后端 Metal %d，录制 %s\n", g_m3 ? 3 : 4, rec_on() ? "开" : "关");
        NSString *dir = @(libdir);
        put_json(dir, @"1111111111111111_b", @{@"stage": @"ts", @"msl_entry_kind": @"object", @"mesh_threads": @32, @"mesh_payload": @4});
        put_json(dir, @"2222222222222222_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"mesh_payload": @4, @"mesh_task": @1, @"max_vertices": @4, @"max_primitives": @2});
        put_json(dir, @"3333333333333333_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"max_vertices": @4, @"max_primitives": @2});
        put_json(dir, @"4444444444444444_b", @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"entry_z": @"main0_z", @"mesh_threads": @32, @"max_vertices": @300, @"max_primitives": @2});
        nvn_be_set_depth_zero(1);

        // ①
        NvShader *ts = shader_get(@"1111111111111111_b", 3), *mt = shader_get(@"2222222222222222_b", 4), *md = shader_get(@"3333333333333333_b", 4);
        VERIFY(ts && ts->mesh_kind == 1 && ts->mesh_threads == 32 && ts->mesh_payload == 4, "① 任务着色器载入：object、线程 32、载荷 4（实得 %d / %u / %u）", ts ? ts->mesh_kind : -1, ts ? ts->mesh_threads : 0, ts ? ts->mesh_payload : 0);
        VERIFY(mt && mt->mesh_kind == 2 && mt->mesh_task && md && md->mesh_kind == 2 && !md->mesh_task, "① 网格着色器载入：2222 带任务、3333 不带");
        VERIFY(mt && md && [mt->ventry isEqual:@"main0_z"] && [md->ventry isEqual:@"main0_z"], "① near = 0 下网格入口是 main0_z（实得 %s / %s）", mt ? mt->ventry.UTF8String : "-", md ? md->ventry.UTF8String : "-");
        REQUIRE(ts && mt && md);
        // ②
        __block NvShader *big = nil; NSString *o = capture(^{ big = shader_get(@"4444444444444444_b", 4); });
        VERIFY(!big && red_lines(o, @"4444444444444444_b") == 1, "② max_vertices 300 的网格着色器载不进、报红 1 行（实得 %s，红 %d 行；stderr：%s）", big ? "载入了" : "nil", red_lines(o, @"4444444444444444_b"), o.UTF8String);

        // ⑪ #418 Switch 1 曲面细分着色器在阶段 3 / 4：json 带 tess、msl_entry_kind 是 vertex / kernel。期望（按约定手写）：不按 task / mesh 契约判——载入成功、不是网格种类、
        //   不打入口类型 / not usable 红行。反证：修前同一份 json 打入口类型红行，再因没有工作组线程数判「not usable」返回 nil
        { NSString *src = [NSString stringWithFormat:@"%@/1111111111111111_b.metallib", dir], *dst = [NSString stringWithFormat:@"%@/5555555555555555_b.metallib", dir];
          [NSFileManager.defaultManager removeItemAtPath:dst error:nil]; REQUIRE([NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:nil]);   // 库内容无关：只验载入时的契约判定
          put_json(dir, @"5555555555555555_b", @{@"stage": @"hs", @"msl_entry_kind": @"vertex", @"tess": @{@"mode": @0}});
          __block NvShader *hs = nil; NSString *o11 = capture(^{ hs = shader_get(@"5555555555555555_b", 3); });
          VERIFY(hs && hs->mesh_kind == 0 && red_lines(o11, @"5555555555555555_b") == 0, "⑪ 曲面细分着色器（阶段 3，带 tess、入口类型 vertex）：载入、非网格种类、0 行红（实得 %s，种类 %d，红 %d 行；stderr：%s）",
                 hs ? "载入了" : "nil", hs ? hs->mesh_kind : -1, red_lines(o11, @"5555555555555555_b"), o11.UTF8String); }

        NvShader *fs = [NvShader new]; fs->stage = 1; strlcpy(fs->key, "ffffffffffffffff_b", sizeof fs->key); fs->ventry = @"main0";
        { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1); }\n" options:nil error:&e]; REQUIRE(l); fs->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs->fn); }
        NvProg *direct = [NvProg new]; direct->sh[1] = fs; direct->sh[4] = md;
        NvProg *task = [NvProg new]; task->sh[1] = fs; task->sh[3] = ts; task->sh[4] = mt;
        NvProg *none = [NvProg new]; none->sh[1] = fs;
        static prog_t gp[3]; NvProg *progs[3] = {direct, task, none};
        for (int i = 0; i < 3; i++) { memset(&gp[i], 0, sizeof gp[i]); gp[i].magic = MAGIC('P', 'R', 'O', 'G'); gp[i].serial = nvn_new_serial(); serial_put(gp[i].serial, progs[i]); }
        rt_make();

        // ③
        frame_begin();
        const prog_t *bound = bind_stages(&gp[1], 0x1a);
        VERIFY(bound == &gp[1], "③ 任务 + 网格 + 片元（位 0x1a）、没有顶点阶段的程序：bind_stages 回它本身（实得 %p，期望 %p）", (const void *)bound, (const void *)&gp[1]);

        // ④
        S.prog = &gp[0]; uint64_t n0 = g_mtk_n; __block int waited = 0;
        p_draw d4 = {.prim = DM_PRIM_MESH_TASKS, .first = 2, .count = 3, .instances = 1};
        o = capture(^{ mesh_draw(&d4, &waited); });
        int cols = frame_columns();
        // 11-13 0400486024DEC000 开局发白：网格管线没编好时一律跳过，不按 skip_safe 的规则。期望（按规则手写）：这是目标第一次被画（近两帧没画过），这笔不能跳过 →
        //   在每帧预算（缺省 250 ms）内等后台那条编好、本笔照画，日志写明原因与「ready」；反证：修前同一处先跳过（waited = 1）、不打这一行
        VERIFY(!waited && [o containsString:@"waited for its background pipeline"] && [o containsString:@"(ready)"] && [o containsString:@"a target not drawn in the last two frames"] && red_lines(o, nil) == 0,
               "④ 首笔管线、目标近两帧没画过：不跳过，等后台编好照画、写明原因、不报红（跳过过 %d；stderr：%s）", waited, o.UTF8String);
        VERIFY(cols == 0x1c && g_mtk_n == n0 + 1, "④ 无任务 first 2 count 3：列 2、3、4 白（列掩码 %#x，期望 0x1c；画出 +%llu）", cols, (unsigned long long)(g_mtk_n - n0));

        // ⑤
        frame_begin(); S.prog = &gp[1];
        p_draw d5 = {.prim = DM_PRIM_MESH_TASKS, .first = 1, .count = 2, .instances = 1};
        o = capture(^{ int w; mesh_draw(&d5, &w); });
        cols = frame_columns();
        VERIFY(cols == 0x3c && red_lines(o, nil) == 0, "⑤ 有任务 first 1 count 2：任务 1、2 各派 2 组 → 列 2..5 白（列掩码 %#x，期望 0x3c；stderr：%s）", cols, o.UTF8String);

        // ⑥ ⑦：参数在内存池里，GPU 在同一提交里写
        static uint32_t pool[4096] __attribute__((aligned(16384)));
        nvn_be_pool_add(pool, sizeof pool);
        pool[0] = 3; pool[1] = 4; pool[4] = 0; pool[5] = 1;   // 种子（GPU 拷贝的源）
        pool[64] = 7; pool[65] = 0; pool[68] = 7; pool[69] = 0;   // 参数位置：CPU 看到的旧值
        frame_begin(); S.prog = &gp[0]; uint64_t i0 = g_mtk_ind_n;
        mtl_sub_copy((uint64_t)(uintptr_t)&pool[0], (uint64_t)(uintptr_t)&pool[64], 8);
        p_draw d6 = {.prim = DM_PRIM_MESH_TASKS, .instances = 1, .ind = (uint64_t)(uintptr_t)&pool[64]};
        o = capture(^{ int w; mesh_draw(&d6, &w); });
        cols = frame_columns();
        VERIFY(cols == 0x70 && g_mtk_ind_n == i0 + 1 && red_lines(o, nil) == 0, "⑥ 间接：GPU 写 {3, 4}（CPU 先见 {7, 0}）→ 列 4、5、6 白（列掩码 %#x，期望 0x70；间接 +%llu；stderr：%s）",
               cols, (unsigned long long)(g_mtk_ind_n - i0), o.UTF8String);
        VERIFY(pool[64] == 3 && pool[65] == 4, "⑥ 参数确实是 GPU 写的：交完后 CPU 读到 {%u, %u}，期望 {3, 4}", pool[64], pool[65]);

        frame_begin(); S.prog = &gp[0]; i0 = g_mtk_ind_n;
        mtl_sub_copy((uint64_t)(uintptr_t)&pool[4], (uint64_t)(uintptr_t)&pool[68], 8);
        p_draw d7 = {.prim = DM_PRIM_MESH_TASKS, .instances = 1, .ind = (uint64_t)(uintptr_t)&pool[68]};
        o = capture(^{ int w; mesh_draw(&d7, &w); });
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_ind_n == i0 + 1 && red_lines(o, nil) == 0, "⑦ 间接零工作量：GPU 写 {0, 1} → 一列不画（列掩码 %#x，期望 0）、照记一笔、不报红（stderr：%s）", cols, o.UTF8String);

        // ④b 目标已连续几帧画过（④–⑦）、这帧开头清过：丢一笔最多影响一帧，新管线照旧后台编、本笔先跳过。期望：跳过过、不打「built on the submit thread」、
        //   等编好再画出列 2、3、4。换一个片元着色器（新键）让管线是第一次遇到
        { NvShader *fs2 = [NvShader new]; fs2->stage = 1; strlcpy(fs2->key, "eeeeeeeeeeeeeeee_b", sizeof fs2->key); fs2->ventry = @"main0";
          NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1, 1, 1, 0.5); }\n" options:nil error:&e]; REQUIRE(l); fs2->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs2->fn);
          NvProg *direct2 = [NvProg new]; direct2->sh[1] = fs2; direct2->sh[4] = md;
          static prog_t gp4b; memset(&gp4b, 0, sizeof gp4b); gp4b.magic = MAGIC('P', 'R', 'O', 'G'); gp4b.serial = nvn_new_serial(); serial_put(gp4b.serial, direct2);
          frame_begin(); S.prog = &gp4b; __block int w4b = 0;
          o = capture(^{ mesh_draw(&d4, &w4b); });
          cols = frame_columns();
          VERIFY(w4b && ![o containsString:@"built on the submit thread"] && red_lines(o, nil) == 0 && cols == 0x1c,
                 "④b 目标稳定且这帧清过：新网格管线后台编、本笔先跳过，编好后画出列 2、3、4（跳过过 %d，列掩码 %#x；stderr：%s）", w4b, cols, o.UTF8String); }

        // ④c 网格管线进本机记录（pso_user.tsv 的 M 行）→ 下一局预热按这行拼回绘制查表用的键、把管线交给表 → 首笔网格绘制直接画（11-13 开局发白根修②）。
        //   期望（按格式手写）：④ 当场编、⑤ 带任务、④b 后台编的三条各记一行 M（⑥ ⑦ 与 ④ 同一条），无任务的第 2 列是「-」、⑤ 那行是任务键 1111…，第 3 列补齐掩码 0；用 ④ 那行（片元 ffff…）解析出的键与
        //   绘制时的键逐字节相同（表里查得到 ④ 的管线）；把表里这条删掉（新开局）后经交接函数放回，同一笔绘制不跳过、不当场编、画出列 2、3、4
        { NSString *txt = [NSString stringWithContentsOfFile:@(pso_user) encoding:NSUTF8StringEncoding error:nil]; NSMutableArray<NSString *> *mrows = [NSMutableArray array];
          for (NSString *l in [txt componentsSeparatedByString:@"\n"]) if ([l hasPrefix:@"M\t"]) [mrows addObject:l];
          NSString *row4 = nil, *row5 = nil;
          for (NSString *l in mrows) { NSArray *c = [l componentsSeparatedByString:@"\t"]; pso_skey sk; if (c.count != 4 || pso_skey_parse([c[1] UTF8String], &sk) || strcmp(sk.fs, "ffffffffffffffff_b")) continue;
              if (!strcmp(sk.vs, "3333333333333333_b")) row4 = l; else if (!strcmp(sk.vs, "2222222222222222_b")) row5 = l; }
          VERIFY(mrows.count == 3 && row4 && [[row4 componentsSeparatedByString:@"\t"][2] isEqual:@"-"] && [[row4 componentsSeparatedByString:@"\t"][3] isEqual:@"0"] &&
                 row5 && [[row5 componentsSeparatedByString:@"\t"][2] isEqual:@"1111111111111111_b"],
                 "④c ④ / ⑤ / ④b 的网格管线各记一行 M（实得 %lu 行），无任务记「-」、⑤ 记任务键、补齐掩码 0（④ 那行第 2、3 列：%s）", (unsigned long)mrows.count,
                 row4 ? [[row4 componentsSeparatedByString:@"\t"] subarrayWithRange:NSMakeRange(2, 2)].description.UTF8String : "无");
          REQUIRE(row4);
          if (!g_shmap) g_shmap = [NSMutableDictionary dictionary];   // 本测没有映射表：把夹具的键登记成本款的（warm_stale 才不当别的游戏版本丢掉）
          for (NSString *k in @[@"1111111111111111", @"2222222222222222", @"3333333333333333", @"ffffffffffffffff", @"eeeeeeeeeeeeeeee"]) g_shmap[k] = @"x";
          long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[@(pso_user)], &lines); WarmTask *t4 = nil;
          for (WarmTask *t in tasks) if (t->kind == 4 && [t->fkey isEqual:@"ffffffffffffffff_b"] && [t->vkey isEqual:@"3333333333333333_b"]) t4 = t;
          VERIFY(t4 && [t4->vkey isEqual:@"3333333333333333_b"] && !t4->tkey.length && t4->pad == 0, "④c 预热解析 M 行：网格键 3333…、片元键 ffff…、无任务、掩码 0（实得 %s / %s / %s / %#x）",
                 t4 ? t4->vkey.UTF8String : "-", t4 ? t4->fkey.UTF8String : "-", t4 ? t4->tkey.UTF8String : "-", t4 ? t4->pad : 0);
          REQUIRE(t4);
          // ④f D-75KF：同一对（④ 那行的 pso_skey、无任务）既有补齐行（掩码 20）又有不补齐行（掩码 0）→ 预热丢掉不补齐那行（它被拒过）；⑤ 那行（有任务键）没有补齐行、照留。
          //   期望（按规则手写）：kind 4 里 3333…/ffff… 无任务的只剩掩码 0x20 一条；⑤ 那条在
          { NSString *rest = [[row4 componentsSeparatedByString:@"\t"][1] copy], *pp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"t_nvn_mesh_pad_rows.tsv"];
            NSString *txt = [NSString stringWithFormat:@"%@\nM\t%@\t-\t20\n%@\n", row4, rest, row5];
            [txt writeToFile:pp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            long ln = 0; NSArray<WarmTask *> *tp = warm_parse(@[pp], &ln); int unpadded = 0, padded = 0, with_task = 0;
            for (WarmTask *t in tp) if (t->kind == 4 && [t->fkey isEqual:@"ffffffffffffffff_b"]) {
                if ([t->vkey isEqual:@"3333333333333333_b"] && !t->tkey.length) { if (t->pad) padded += t->pad == 0x20; else unpadded++; }
                else if (t->tkey.length) with_task++; }
            VERIFY(unpadded == 0 && padded == 1 && with_task == 1 && ln == 2, "④f 同对有补齐行时预热丢掉不补齐那行（实得 不补齐 %d / 补齐 %d / 带任务 %d / 行数 %ld，期望 0 / 1 / 1 / 2）", unpadded, padded, with_task, ln);
            [NSFileManager.defaultManager removeItemAtPath:pp error:nil]; }
          pso_skey sk; [t4->rs[0] getBytes:&sk length:sizeof sk]; mtk_key mk; mtk_warm_key(&sk, NULL, md, fs, 0, &mk);
          os_unfair_lock_lock(&g_pso_mtk_lock); id had = hm_get_id(&g_pso_mtk, &mk); os_unfair_lock_unlock(&g_pso_mtk_lock);
          VERIFY(had && had != NSNull.null && had != g_pso_mtk_building, "④c 按 M 行拼回的键在网格管线表里查得到 ④ 编好的那条（%p）", (__bridge void *)had);
          REQUIRE(had);
          os_unfair_lock_lock(&g_pso_mtk_lock); hm_del_id(&g_pso_mtk, &mk); os_unfair_lock_unlock(&g_pso_mtk_lock);
          uint64_t wc0 = g_mtk_warm_claimed; mtk_warm_claim([NSData dataWithBytes:&mk length:sizeof mk], had);
          VERIFY(g_mtk_warm_claimed == wc0 + 1, "④c 交接：表里没有这条时，预热交来的管线放进表（交接 +%llu）", (unsigned long long)(g_mtk_warm_claimed - wc0));
          frame_begin(); S.prog = &gp[0]; uint64_t sn0 = g_mtk_waits; __block int w4c = 0;
          o = capture(^{ mesh_draw(&d4, &w4c); });
          cols = frame_columns();
          VERIFY(!w4c && g_mtk_waits == sn0 && cols == 0x1c && red_lines(o, nil) == 0,
                 "④c 预热交来的管线：同一笔不跳过、不用等、画出列 2、3、4（跳过过 %d，等待 +%llu，列掩码 %#x；stderr：%s）", w4c, (unsigned long long)(g_mtk_waits - sn0), cols, o.UTF8String); }
        unlink(pso_user);

        // ④d（D-84J2 起）丢不起的那笔等到管线编好，只受「编译服务卡死」封顶（DM_NVN_PSO_UNSAFE_WAIT_MS，这里设 300 ms）：编译被挂住时等满封顶才跳过、打红行并写明是封顶。
        //   新目标（近两帧没画过）+ 新片元（管线没编过）。④e：编译在等待中途放开 → 等到编好就画出，不计跳过、没有红行
        { tex_t rt2; memset(&rt2, 0, sizeof rt2); rt2.magic = MAGIC('T', 'E', 'X', 0); rt2.serial = nvn_new_serial(); rt2.d = g_rt.d; nvn_tex_layout(&rt2.d, &rt2.L); nvn_be_tex_init(&rt2); REQUIRE(tex_mtl(&rt2));
          NvShader *fs3 = [NvShader new]; fs3->stage = 1; strlcpy(fs3->key, "dddddddddddddddd_b", sizeof fs3->key); fs3->ventry = @"main0";
          NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1, 1, 1, 0.25); }\n" options:nil error:&e]; REQUIRE(l); fs3->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs3->fn);
          NvProg *direct3 = [NvProg new]; direct3->sh[1] = fs3; direct3->sh[4] = md;
          static prog_t gp4d; memset(&gp4d, 0, sizeof gp4d); gp4d.magic = MAGIC('P', 'R', 'O', 'G'); gp4d.serial = nvn_new_serial(); serial_put(gp4d.serial, direct3);
          nvn_be_set_frame(++g_frame); nvn_be_sub_begin(); state_reset();
          const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr end; } c = {
              .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &rt2, .end = {OP_END, sizeof(op_hdr)} };
          nvn_be_exec((const uint8_t *)&c);
          // 后台编译先挂住（占满后台并发名额 g_mtk_sem）：这笔管线在检查时一定还没编好，期望不靠编译快慢。
          //   原先不挂：门禁机编得快（0.1 ms 编好），检查时已能画、没走「跳过」，超预算 +0 / 跳过 +0（main c3708ffdb 已知红）
          REQUIRE(g_mtk_sem); int held = mtk_width(); for (int i = 0; i < held; i++) dispatch_semaphore_wait(g_mtk_sem, DISPATCH_TIME_FOREVER);
          int b0 = g_mtk_budget, u0 = g_pso_unsafe_ms; g_mtk_budget = 0; g_pso_unsafe_ms = 300; S.prog = &gp4d; uint64_t ov0 = g_mtk_wait_over, w0 = g_mtk_wait, mx0 = g_mtk_wait_max;
          uint64_t t4d = bp_now(); o = capture(^{ draw(&d4, NULL); }); double ms4d = (bp_now() - t4d) / 1e6;
          g_mtk_budget = b0; g_pso_unsafe_ms = u0; for (int i = 0; i < held; i++) dispatch_semaphore_signal(g_mtk_sem);
          dispatch_group_wait(g_mtk_group, DISPATCH_TIME_FOREVER);
          rp_flush(); uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));
          (void)mx0;
          VERIFY(g_mtk_wait_over == ov0 + 1 && g_mtk_wait == w0 + 1 && ms4d >= 300 && [o containsString:@"stuck-compiler cap DM_NVN_PSO_UNSAFE_WAIT_MS 300 ms"] && [o containsString:@"not ready: skipped this frame"] && red_lines(o, nil) == 1,
                 "④d 编译挂住：丢不起的那笔等满封顶 300 ms 才跳过、计数、打一条红行写明封顶（等了 %.0f ms，超时 +%llu，跳过 +%llu；stderr：%s）", ms4d, (unsigned long long)(g_mtk_wait_over - ov0), (unsigned long long)(g_mtk_wait - w0), o.UTF8String);
          // 这笔从没画出来过，它的管线在请求编译时就进了本机记录（M 行，片元键 dddd…）。反证：只在第一次画出时记，这里就没有
          int rec4d = 0; pso_user_seen_load();
          for (NSString *l in g_pso_user_seen) { if (![l hasPrefix:@"M\t"]) continue; pso_skey sk; NSArray *c = [l componentsSeparatedByString:@"\t"];
              if (c.count >= 2 && !pso_skey_parse([c[1] UTF8String], &sk) && !strcmp(sk.fs, "dddddddddddddddd_b")) rec4d++; }
          VERIFY(rec4d == 1, "④d 没画出来过的网格管线在请求编译时就记了一行 M（实得 %d 行）", rec4d); }
        // ④e 同样丢不起的一笔（又一张新目标 + 又一个新片元），编译挂住约 100 ms 后放开：这笔等到管线编好就画出——不跳过、不计超时、没有红行，等待 ≥ 挂住的时长
        { tex_t rt3; memset(&rt3, 0, sizeof rt3); rt3.magic = MAGIC('T', 'E', 'X', 0); rt3.serial = nvn_new_serial(); rt3.d = g_rt.d; nvn_tex_layout(&rt3.d, &rt3.L); nvn_be_tex_init(&rt3); REQUIRE(tex_mtl(&rt3));
          NvShader *fs4 = [NvShader new]; fs4->stage = 1; strlcpy(fs4->key, "eeeeeeeeeeeeeeee_b", sizeof fs4->key); fs4->ventry = @"main0";
          NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1, 1, 1, 0.5); }\n" options:nil error:&e]; REQUIRE(l); fs4->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs4->fn);
          NvProg *direct4 = [NvProg new]; direct4->sh[1] = fs4; direct4->sh[4] = md;
          static prog_t gp4e; memset(&gp4e, 0, sizeof gp4e); gp4e.magic = MAGIC('P', 'R', 'O', 'G'); gp4e.serial = nvn_new_serial(); serial_put(gp4e.serial, direct4);
          nvn_be_set_frame(++g_frame); nvn_be_sub_begin(); state_reset();
          const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr end; } c = {
              .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &rt3, .end = {OP_END, sizeof(op_hdr)} };
          nvn_be_exec((const uint8_t *)&c);
          int held = mtk_width(); for (int i = 0; i < held; i++) dispatch_semaphore_wait(g_mtk_sem, DISPATCH_TIME_FOREVER);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ for (int i = 0; i < held; i++) dispatch_semaphore_signal(g_mtk_sem); });
          int b0 = g_mtk_budget, u0 = g_pso_unsafe_ms; g_mtk_budget = 0; g_pso_unsafe_ms = 10000; S.prog = &gp4e; uint64_t ov0 = g_mtk_wait_over, w0 = g_mtk_wait, n0 = g_mtk_n;
          uint64_t t4e = bp_now(); NSString *o4 = capture(^{ draw(&d4, NULL); }); double ms4e = (bp_now() - t4e) / 1e6;
          g_mtk_budget = b0; g_pso_unsafe_ms = u0;
          dispatch_group_wait(g_mtk_group, DISPATCH_TIME_FOREVER);
          rp_flush(); uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));
          VERIFY(g_mtk_wait_over == ov0 && g_mtk_wait == w0 && g_mtk_n == n0 + 1 && ms4e >= 100 && ms4e < 10000 && red_lines(o4, nil) == 0,
                 "④e 编译 100 ms 后放开：丢不起的那笔等到编好就画出（等了 %.0f ms，画出 +%llu，跳过 +%llu，超时 +%llu；stderr：%s）", ms4e, (unsigned long long)(g_mtk_n - n0), (unsigned long long)(g_mtk_wait - w0), (unsigned long long)(g_mtk_wait_over - ov0), o4.UTF8String); }

        // ⑧
        frame_begin(); S.prog = &gp[2]; uint64_t s0 = g_mtk_skip;
        p_draw d8 = {.prim = DM_PRIM_MESH_TASKS, .first = 0, .count = 4, .instances = 1};
        o = capture(^{ draw(&d8, NULL); draw(&d8, NULL); });
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_skip == s0 + 2 && red_lines(o, nil) == 1, "⑧ 程序没有网格着色器：两笔都跳过（+%llu）、报红 1 行、不画（列掩码 %#x；stderr：%s）", (unsigned long long)(g_mtk_skip - s0), cols, o.UTF8String);
        nvn_be_pool_del(pool);

        // ⑨
        int st_t = stage_of(@"task"), st_m = stage_of(@"mesh");
        NvShader *mt9 = st_t >= 0 ? shader_get(@"1111111111111111_b", st_t) : nil, *mm9 = st_m >= 0 ? shader_get(@"3333333333333333_b", st_m) : nil;
        VERIFY(st_t == 3 && st_m == 4 && mt9 && mt9->mesh_kind == 1 && mm9 && mm9->mesh_kind == 2,
               "⑨ 映射表阶段名 task / mesh → 宿主阶段 3 / 4 并载入 object / mesh（实得 %d / %d，种类 %d / %d）", st_t, st_m, mt9 ? mt9->mesh_kind : -1, mm9 ? mm9->mesh_kind : -1);

        // ⑩
        frame_begin(); S.prog = &gp[0]; s0 = g_mtk_skip; n0 = g_mtk_n; int ok_saved = g_mesh_ok; g_mesh_ok = 0;
        p_draw d10 = {.prim = DM_PRIM_MESH_TASKS, .first = 0, .count = 4, .instances = 1};
        o = capture(^{ draw(&d10, NULL); draw(&d10, NULL); });
        g_mesh_ok = ok_saved;
        cols = frame_columns();
        VERIFY(cols == 0 && g_mtk_skip == s0 + 2 && g_mtk_n == n0 && red_lines(o, @"no object / mesh pipelines") == 1,
               "⑩ GPU 无网格管线：两笔都跳过（+%llu）、报红 1 行、不画（列掩码 %#x；stderr：%s）", (unsigned long long)(g_mtk_skip - s0), cols, o.UTF8String);

        // ⑫ #1208 GPU 挂死隔离收网格管线：一条网格管线（网格 3333… + 新片元 cccc…）第一次画出 → 进本提交的嫌疑（quar_take 里有「3333333333333333\tcccccccccccccccc」，
        //   格式同普通管线的 quar_name：两键各前 16 字）；这批嫌疑报错隔离后，同一对的网格绘制跳过、不画、报红 1 行点名隔离，并写进隔离表（以后的局也跳过）。
        //   反证：改前 mtk_pso 不调 quar_built / quar_has —— 嫌疑里没有它（GPU 在这次提交挂死时什么都不隔离，下一局挂在同一处），隔离后照画列 0..3
        { NvShader *fs5 = [NvShader new]; fs5->stage = 1; strlcpy(fs5->key, "cccccccccccccccc_b", sizeof fs5->key); fs5->ventry = @"main0";
          NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1); }\n" options:nil error:&e]; REQUIRE(l); fs5->fn = [l newFunctionWithName:@"main0"]; REQUIRE(fs5->fn);
          NvProg *direct5 = [NvProg new]; direct5->sh[1] = fs5; direct5->sh[4] = md;
          static prog_t gp12; memset(&gp12, 0, sizeof gp12); gp12.magic = MAGIC('P', 'R', 'O', 'G'); gp12.serial = nvn_new_serial(); serial_put(gp12.serial, direct5);
          NSString *pair = @"3333333333333333\tcccccccccccccccc";
          frame_begin(); (void)quar_take(); S.prog = &gp12;
          p_draw d12 = {.prim = DM_PRIM_MESH_TASKS, .first = 0, .count = 4, .instances = 1};
          __block int w12 = 0; o = capture(^{ mesh_draw(&d12, &w12); });
          NSArray<NSString *> *sus = quar_take();   // 提交前取：frame_columns 的提交会自己取走
          cols = frame_columns();
          VERIFY(cols == 0x0f && [sus containsObject:pair] && [o containsString:@"first drawn"],
                 "⑫ 网格管线第一次画出：画出列 0..3、进本提交的 GPU 出错嫌疑、打 first drawn（列掩码 %#x，嫌疑 %s；stderr：%s）", cols, [sus componentsJoinedByString:@" | "].UTF8String, o.UTF8String);
          quar_fault(sus, [NSError errorWithDomain:@"t" code:1 userInfo:nil]);
          frame_begin(); uint64_t q0 = g_mtk_quar_skip; S.prog = &gp12;
          o = capture(^{ draw(&d12, NULL); draw(&d12, NULL); });
          cols = frame_columns();
          NSString *qf = [NSString stringWithContentsOfFile:[@(pdir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
          VERIFY(quar_has(md, fs5) && cols == 0 && g_mtk_quar_skip == q0 + 2 && red_lines(o, @"quarantine") == 2 && [qf containsString:pair],
                 "⑫ 隔离后同一对网格绘制两笔都跳过（+%llu）、不画（列掩码 %#x）、每笔报红 1 行（全局前 4 笔）、写进隔离表（%s；stderr：%s）",
                 (unsigned long long)(g_mtk_quar_skip - q0), cols, [qf containsString:pair] ? "有" : "无", o.UTF8String);
          unlink([[@(pdir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"] fileSystemRepresentation]); rmdir(pdir); }
    }
    if (failures) { printf("✗ t_nvn_mesh：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_mesh：%u 项全过（任务 / 网格绘制：约定字段载入、上限报红、无顶点阶段的程序、直接 / 有任务 / GPU 写参数的间接 / 零工作量画出的列与手算一致、缺网格着色器报红、映射表阶段名 task / mesh 载入、无网格管线的 GPU 跳过报红）\n", checks); return 0;
}
