// 反射绑定数（nvn_refl_from_json）：绑定数组按反射里的个数分配。期望值手写：71 个绑定（怪猎崛起 12 个着色器，最大 71；暗黑2 24 个超 64）解析成功、逐个对上；
//   超过参数缓冲上限（NVN_REFL_MAXARG）才拒；改前固定 64 时 71 个报「over the limit 64」（反证：同一单测编改前的 nvn_refl.m 即不过）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSDictionary *refl_with(int n) {
    NSMutableArray *b = [NSMutableArray array];
    for (int i = 0; i < n; i++) [b addObject:@{ @"kind": @"cbuf", @"reg": @(i % 14), @"arg_id": @(i), @"msl_name": [NSString stringWithFormat:@"fp_c%d", 3 + i % 14] }];
    return @{ @"route": @"B", @"bindings": b };
}

int main(void) {
    @autoreleasepool {
        char err[256] = "";
        NvShader *s = [NvShader new];
        int rc = nvn_refl_from_json(refl_with(71), &s->rf, err, sizeof err);
        VERIFY(rc == 0 && s->rf.nb == 71, "71 个绑定解析成功（rc %d，nb %d%s%s）", rc, s->rf.nb, err[0] ? "，" : "", err);
        int ok = rc == 0; for (int i = 0; ok && i < 71; i++) ok = s->rf.b[i].kind == NVN_RB_CBUF && s->rf.b[i].aid == i && s->rf.b[i].reg == i % 14;
        VERIFY(ok, "71 个绑定逐个对上（种类、参数缓冲项、槽号）");
        s = nil;   // dealloc 释放 b 与 c1

        NvShader *t = [NvShader new]; err[0] = 0;
        rc = nvn_refl_from_json(refl_with(NVN_REFL_MAXARG + 1), &t->rf, err, sizeof err);
        VERIFY(rc != 0 && strstr(err, "argument buffer limit") && !t->rf.b, "超过参数缓冲上限 %d 才拒、失败路径释放绑定数组（%s）", NVN_REFL_MAXARG, err);

        // 存储缓冲可写（10-27 异度3 人物蒙皮：出包写的 "rw" 恒为 false，非 const 的 device 类型才是真话）：rw 真 → 可写；rw 假但类型 "device _23*" → 可写；
        //   rw 假、类型 "const device _25*" → 只读；没有 rw、类型 const → 只读；没有 rw 也没有类型 → 可写（宁可多记写）
        NSDictionary *sb[5] = { @{ @"rw": @YES, @"msl_type": @"const device _25*" }, @{ @"rw": @NO, @"msl_type": @"device _23*" }, @{ @"rw": @NO, @"msl_type": @"const device _25*" },
                                @{ @"msl_type": @"const device _25*" }, @{} };
        const int want[5] = {1, 1, 0, 0, 1}; int got[5];
        for (int i = 0; i < 5; i++) {
            NSMutableDictionary *b = [sb[i] mutableCopy]; b[@"kind"] = @"sbuf"; b[@"reg"] = @0; b[@"arg_id"] = @0; b[@"msl_name"] = @"vp_s0";
            NvShader *u = [NvShader new]; err[0] = 0; int r2 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[b] }, &u->rf, err, sizeof err);
            got[i] = r2 == 0 && u->rf.nb == 1 ? u->rf.b[0].rw : -1;
        }
        VERIFY(!memcmp(got, want, sizeof want), "存储缓冲可写判定：rw 真 / rw 假但非 const / rw 假且 const / 无 rw 且 const / 都没有 → 1 1 0 0 1（实得 %d %d %d %d %d）", got[0], got[1], got[2], got[3], got[4]);

        // 地址推在 NVN2 推常量槽里的存储缓冲（Dsh.cs sbuf_push → SBUFQ）。期望手写：① 槽 1 + 0x10、rw 真 → SBUFQ / reg 1 / off 0x10 / 可写；
        //   ② 槽 7 + 0xf8（末尾 8 字节）→ 成功；③ 槽 8、④ 偏移 0xf9（8 字节越出 256）、⑤ 没给槽 → 拒（错误写明推常量槽）。反证：同一单测编改前的 nvn_refl.m，① 报「kind sbuf_push not implemented」
        {
            NSDictionary *pq[5] = { @{ @"reg": @1, @"off": @0x10, @"rw": @YES }, @{ @"reg": @7, @"off": @0xf8 }, @{ @"reg": @8, @"off": @0 }, @{ @"reg": @1, @"off": @0xf9 }, @{ @"off": @0 } };
            int rq[5]; NvShader *qs[5]; char qe[5][256];
            for (int i = 0; i < 5; i++) {
                NSMutableDictionary *b = [pq[i] mutableCopy]; b[@"kind"] = @"sbuf_push"; b[@"arg_id"] = @0; b[@"msl_name"] = @"cp_s0"; b[@"msl_type"] = @"device _12*";
                qs[i] = [NvShader new]; qe[i][0] = 0; rq[i] = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[b] }, &qs[i]->rf, qe[i], sizeof qe[i]);
            }
            VERIFY(rq[0] == 0 && qs[0]->rf.nb == 1 && qs[0]->rf.b[0].kind == NVN_RB_SBUFQ && qs[0]->rf.b[0].reg == 1 && qs[0]->rf.b[0].off == 0x10 && qs[0]->rf.b[0].rw,
                   "① sbuf_push 槽 1 + 0x10 → SBUFQ（rc %d %s）", rq[0], qe[0]);
            VERIFY(rq[1] == 0 && qs[1]->rf.b[0].kind == NVN_RB_SBUFQ && qs[1]->rf.b[0].reg == 7 && qs[1]->rf.b[0].off == 0xf8, "② 槽 7 末尾 8 字节 → 成功（rc %d %s）", rq[1], qe[1]);
            VERIFY(rq[2] && strstr(qe[2], "push slot") && rq[3] && strstr(qe[3], "push slot") && rq[4] && strstr(qe[4], "push slot"),
                   "③ 槽 8 / ④ 偏移越出 256 / ⑤ 没给槽 → 拒（%s | %s | %s）", qe[2], qe[3], qe[4]);
        }

        // 分离句柄对的采样器半边声明成数组（Dsh.cs C2Array：贴图半边按运行时下标取 c2 表，采样器是一个常量分离采样器槽）：kind samp + array<sampler, 32> → SAMP、n 32（宿主每项填同一个）；
        //   array<sampler, 33> → 拒。反证：同一单测编改前的 nvn_refl.m，n 是 0（宿主只填第 0 项，其余 31 项空）
        {
            NvShader *sa = [NvShader new]; err[0] = 0;
            int r5 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[ @{ @"kind": @"samp", @"reg": @1, @"arg_id": @39, @"msl_name": @"fp_t2d_cb196610_10570000Smplr", @"msl_type": @"array<sampler, 32>" } ] }, &sa->rf, err, sizeof err);
            VERIFY(r5 == 0 && sa->rf.nb == 1 && sa->rf.b[0].kind == NVN_RB_SAMP && sa->rf.b[0].reg == 1 && sa->rf.b[0].n == 32, "采样器数组 → SAMP 槽 1、n 32（rc %d n %d %s）", r5, r5 == 0 ? sa->rf.b[0].n : -1, err);
            NvShader *sb2 = [NvShader new]; err[0] = 0;
            r5 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[ @{ @"kind": @"samp", @"reg": @1, @"arg_id": @0, @"msl_name": @"fp_s", @"msl_type": @"array<sampler, 33>" } ] }, &sb2->rf, err, sizeof err);
            VERIFY(r5 != 0 && strstr(err, "array of 33"), "采样器数组 33 项 → 拒（%s）", err);
        }

        // #798 前导项配对（11-16 回归：几何变体的拓扑缓冲 trb_data 在反射里是几何辅助缓冲，原先整支判「no texel buffer of that name」、几何核编不出）。期望手写：
        //   ① 前导项指向几何辅助缓冲 → 解析成功、两边都不配对（tbl 0，has_tbl 0：前导数按 0 走）；② 指向纹素缓冲 → 照常互指（#798 原行为）；
        //   ③ 名字找不到 → 照旧报错；④ 指向别的种类（常量缓冲）→ 照旧报错。反证：同一单测编改前的 nvn_refl.m，① 红
        {
            NvShader *g = [NvShader new]; err[0] = 0;
            int r3 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[
                @{ @"kind": @"geometry", @"reg": @4, @"arg_id": @5, @"msl_name": @"trb_data" },
                @{ @"kind": @"tblead", @"for": @"trb_data", @"arg_id": @6, @"msl_name": @"gal_tbl_trb_data" } ] }, &g->rf, err, sizeof err);
            VERIFY(r3 == 0 && g->rf.b && g->rf.nb == 2 && g->rf.b[0].kind == NVN_RB_GEOMETRY && g->rf.b[1].kind == NVN_RB_TBLEAD && !g->rf.b[0].tbl && !g->rf.b[1].tbl && !g->rf.has_tbl,
                   "① 前导项指向几何拓扑缓冲：解析成功、不配对（rc %d nb %d tbl %d/%d has_tbl %d%s%s）", r3, g->rf.nb, g->rf.b && g->rf.nb > 1 ? g->rf.b[0].tbl : -1, g->rf.b && g->rf.nb > 1 ? g->rf.b[1].tbl : -1, g->rf.has_tbl, err[0] ? "，" : "", err);
            NvShader *p = [NvShader new]; err[0] = 0;
            r3 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[
                @{ @"kind": @"tbuf", @"reg": @3, @"arg_id": @0, @"msl_name": @"vp_tb3", @"msl_type": @"texture_buffer<float>" },
                @{ @"kind": @"tblead", @"for": @"vp_tb3", @"arg_id": @1, @"msl_name": @"gal_tbl_vp_tb3" } ] }, &p->rf, err, sizeof err);
            VERIFY(r3 == 0 && p->rf.b && p->rf.nb == 2 && p->rf.b[0].tbl == 2 && p->rf.b[1].tbl == 1 && p->rf.has_tbl, "② 前导项指向纹素缓冲：照常互指（rc %d tbl %d/%d has_tbl %d%s%s）",
                   r3, p->rf.b && p->rf.nb > 1 ? p->rf.b[0].tbl : -1, p->rf.b && p->rf.nb > 1 ? p->rf.b[1].tbl : -1, p->rf.has_tbl, err[0] ? "，" : "", err);
            NvShader *im = [NvShader new]; err[0] = 0;   // ⑤ 前导项指向图像纹素缓冲（可写 texture_buffer）：解析成功、不配对
            r3 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[
                @{ @"kind": @"img", @"reg": @2, @"arg_id": @0, @"msl_name": @"cp_i_cb2_48_rgba8", @"msl_type": @"texture_buffer<float, access::read_write>" },
                @{ @"kind": @"tblead", @"for": @"cp_i_cb2_48_rgba8", @"arg_id": @1, @"msl_name": @"gal_tbl_cp_i_cb2_48_rgba8" } ] }, &im->rf, err, sizeof err);
            VERIFY(r3 == 0 && im->rf.b && im->rf.nb == 2 && im->rf.b[0].kind == NVN_RB_IMG && !im->rf.b[0].tbl && !im->rf.b[1].tbl && !im->rf.has_tbl,
                   "⑤ 前导项指向图像纹素缓冲：解析成功、不配对（rc %d%s%s）", r3, err[0] ? "，" : "", err);
            NvShader *m = [NvShader new]; err[0] = 0;
            r3 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[ @{ @"kind": @"tblead", @"for": @"nowhere", @"arg_id": @0, @"msl_name": @"gal_tbl_nowhere" } ] }, &m->rf, err, sizeof err);
            VERIFY(r3 != 0 && strstr(err, "no texel buffer of that name"), "③ 前导项名字找不到：照旧报错（%s）", err);
            NvShader *c = [NvShader new]; err[0] = 0;
            r3 = nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[
                @{ @"kind": @"cbuf", @"reg": @3, @"arg_id": @0, @"msl_name": @"fp_c3" },
                @{ @"kind": @"tblead", @"for": @"fp_c3", @"arg_id": @1, @"msl_name": @"gal_tbl_fp_c3" } ] }, &c->rf, err, sizeof err);
            VERIFY(r3 != 0 && strstr(err, "no texel buffer of that name"), "④ 前导项指向常量缓冲：照旧报错（%s）", err);
        }

        {   // #bbd549：反射写了回放层填不了的驱动段位置（drv_unfillable）：不再整支判失败（原先程序不可用、用它的绘制全被跳过），照常解析、记 drv_unfilled、err 里是原样清单
            NvShader *u = [NvShader new]; err[0] = 'x'; err[1] = 0;
            int ru = nvn_refl_from_json(@{ @"route": @"B", @"drv_unfillable": @[ @"c0 dynamic index", @"c0+0x630" ],
                @"bindings": @[ @{ @"kind": @"cbuf", @"reg": @3, @"arg_id": @0, @"msl_name": @"fp_c3" } ] }, &u->rf, err, sizeof err);
            VERIFY(ru == 0 && u->rf.drv_unfilled == 1 && u->rf.nb == 1 && strstr(err, "c0 dynamic index c0+0x630"),
                   "⑥ 填不了的驱动段位置：解析成功、drv_unfilled=1、绑定 1 个、清单「c0 dynamic index c0+0x630」（rc %d，drv_unfilled %d，%s）", ru, u->rf.drv_unfilled, err);
            NvShader *v = [NvShader new]; err[0] = 'x'; err[1] = 0;
            int rv = nvn_refl_from_json(@{ @"route": @"B", @"drv_unfillable": @[], @"bindings": @[] }, &v->rf, err, sizeof err);
            VERIFY(rv == 0 && v->rf.drv_unfilled == 0 && err[0] == 0, "⑦ 清单为空：drv_unfilled=0、err 清空（rc %d，drv_unfilled %d，err「%s」）", rv, v->rf.drv_unfilled, err);
        }

        // #1106: NVN order differs from Maxwell's; expectations are literal ABI offsets.
        const int bases[6] = {0x110, 0x510, 0x410, 0x210, 0x310, 0x310};
        for (int stage = 0; stage < 6; stage++)
            VERIFY(c0_ssbo_base(stage, 0) == bases[stage], "c0 stage %d base %#x（期望 %#x）", stage, c0_ssbo_base(stage, 0), bases[stage]);
        VERIFY(c0_ssbo_base(-1, 0) == -1 && c0_ssbo_base(6, 0) == -1, "未知阶段不返回存储缓冲基址");
        // NVN2 任务 / 网格着色器（mesh 1 / 2）：c0 存储表在 0x670 / 0x770（网格着色接口约定第 4 条），与所在宿主阶段无关
        VERIFY(c0_ssbo_base(3, 1) == 0x670 && c0_ssbo_base(4, 2) == 0x770 && c0_ssbo_base(0, 2) == 0x770, "任务 / 网格存储表基址 0x670 / 0x770（实得 %#x / %#x）", c0_ssbo_base(3, 1), c0_ssbo_base(4, 2));

        // Real shared Metal buffers, filled by production encode_args, not a duplicate table writer.
        mtl_init(); arena_begin();
        g_dispatch_dim[0] = 3; g_dispatch_dim[1] = 5; g_dispatch_dim[2] = 7;
        g_draw_binst = 11;
        for (int stage = 0; stage < 6; stage++) {
            uint8_t expected[DRV_SIZE] = {0};
            for (int r = 0; r < 16; r++) {
                uint64_t addr = 0x1234000000ull + 0x100000 * stage + 0x1000 * r;
                uint32_t size = 0x400 + 17 * r;
                S.ssbo[stage][r].addr = addr; S.ssbo[stage][r].size = size;
                memcpy(expected + bases[stage] + 16 * r, &addr, 8);
                memcpy(expected + bases[stage] + 16 * r + 8, &size, 4);
            }
            if (stage != 5) {
                const float max_point = 2047.0f;
                memcpy(expected + 0x610, &max_point, 4); memcpy(expected + 0x644, &g_draw_binst, 4);
            } else memcpy(expected + 0x200, g_dispatch_dim, 12);
            NvShader *driver = [NvShader new]; driver->stage = stage; driver->arg_len = 8;
            driver->rf.b = calloc(1, sizeof *driver->rf.b); driver->rf.nb = 1;
            driver->rf.b[0].kind = NVN_RB_DRV0; driver->rf.drv_read[0] = 1;
            args_dirty_all(); int encoded = encode_args(nil, driver, stage, stage != 1);
            uint64_t gpu = 0; if (driver->ab_buf) memcpy(&gpu, (uint8_t *)driver->ab_buf.contents + driver->ab_off, 8);
            const uint8_t *bytes = NULL;
            for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu + DRV_SIZE <= a->gpu + a->buf.length)
                bytes = (const uint8_t *)a->buf.contents + (gpu - a->gpu);
            VERIFY(encoded && bytes && !memcmp(bytes, expected, DRV_SIZE), "c0 stage %d：实际编码缓冲逐字节对齐16个地址/大小与表外围（base %#x）", stage, bases[stage]);
        }
    }
    if (failures) { printf("✗ t_nvn_refl：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_refl：%u 项全过（绑定数组按个数分配：71 个照收，超参数缓冲上限才拒；存储缓冲可写按 rw 或非 const 类型）\n", checks); return 0;
}
