// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Switch 1 着色器键第 2 代（graphics/nvn/gfx/nvn/nvn_key.h）与宿主旧包兜底（hle_nvn.c keys_hash + nvn_mtl.m nvn_be_shader_key_pick）。
// 夹具：控制段 0x880 字节 ctl[i] = (i*7+3) & 0xff，+0x20 自报长度 own，+0x704 = 0x40；代码区 0x40 字节 code[i] = (i*13+5) & 0xff，前 4 字节 78 56 34 12。
// 期望值按规则用 Python hashlib 逐字节手算（不经被测实现）：v1 = sha256(ctl[:n] ‖ code)[:8]，v2 = 同上但 ctl 的 [0x790,0x798)、[0x7d0,0x7e8) 落在 n 内的字节先置 0；
//   n = own ∈ [0x760, 0x880) 时取 own，否则 0x880
//   A own 0x880                       v1 404d87c7549fd09c  v2 e0d0ef6990987e99
//   B = A 两段按位异或 5a / a5         v1 1dee7e8e37634f1d  v2 e0d0ef6990987e99（与 A 同 v2、不同 v1）
//   C = A 的 +0x100 改一位             v1 18e4a9d2f3ced205  v2 4aa6cc1d9c43e270（差在别处：v2 不同）
//   D own 0x7e0（第二段只置零到 0x7e0） v1 54daf52547a5a9b4  v2 2729eeba92fce15e
//   E = D 的 +0x792、+0x7d8 取反       v1 057da50789e2819a  v2 2729eeba92fce15e（只差 nctl 内的两段）
//   F = D 的 +0x7e4 取反（nctl 之外）  v1 54daf52547a5a9b4  v2 2729eeba92fce15e
//   N2 Switch 2 控制段（魔数 98761234、版本 c9，ctl[i] = (i*5+1) & 0xff、+0x44 = 0x40）nvn2_key = d84a694ffca1c9c9（规则 nvn2.h，本次未改）
// 旧包兜底（包表 = shader_map.tsv，经 nvn_be_reload_direct_library 换表；兜底目录 = DM_MSL_FALLBACK）：
//   ① 包表只有 A 的 v1 → prog_key 取 v1；prog_key_live 同取 v1（首用复核同一规则）
//   ② 只有 v2 → v2   ③ 都没有 → v2   ④ 都有 → v2
//   ⑤ 包表都没有、兜底目录有旧版本按 v1 现编的产物（链号、翻译器指纹与本机相同）→ v1
// 读档换键 R1–R3 的期望与反证见用例处。
// 反证：keys_hash 不置零 → A / B 的 v2 期望红；去掉兜底（不调 nvn_be_shader_key_pick）→ ①⑤ 红；兜底先查 v1 → ④ 红
#include "../gfx/nvn/nvn_mtl.m"

int s2a_hle_pk_load(FILE *f);   // hle_nvn.c：读档放回程序键表
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 兜底目录复用要核翻译器指纹（dsh_miss.inc dsh_have 经 dlsym 取 s2a_dsh_xfp）；单测不链 S2A.Aot，这里给一个固定值
__attribute__((used, visibility("default"))) const char *s2a_dsh_xfp(void) { return "00112233aabbccdd"; }

static uint8_t g_code[0x40];
static void mk_ctl(uint8_t *c, uint32_t own) {
    for (unsigned i = 0; i < 0x880; i++) c[i] = (uint8_t)(i * 7 + 3);
    uint32_t n = 0x40; memcpy(c + 0x20, &own, 4); memcpy(c + 0x704, &n, 4);
}
// 一个只有阶段 0 的程序；每次新对象（键表按程序地址记，prog_key 只在第一次算）
static prog_t *mk_prog(const uint8_t *ctl) {
    prog_t *p = calloc(1, sizeof *p); REQUIRE(p);
    p->nstage = 1; p->sd[0].control = (void *)ctl; p->sd[0].data = (uint64_t)(uintptr_t)g_code; return p;
}
static NSString *hex8(const uint8_t k[8]) { return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]]; }
static NSString *key_of(const uint8_t *ctl) { uint8_t k[8] = {0}; REQUIRE(prog_key(mk_prog(ctl), 0, k)); return hex8(k); }
static void put_text(NSString *path, NSString *t) {
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
    REQUIRE([t writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]);
}
// 换包表：目录 d 下的 shader_map.tsv 只列 keys（第 3 列阶段、第 4 列键，shmap_load_once 读 c[2] / c[3]）
static void use_map_alias(NSString *root, NSString *name, NSArray<NSString *> *keys, NSString *alias) {
    NSString *d = [root stringByAppendingPathComponent:name]; NSMutableString *t = [NSMutableString string];
    for (NSString *k in keys) [t appendFormat:@"x\tx\tvertex\t%@\n", k];
    put_text([d stringByAppendingPathComponent:@"shader_map.tsv"], t);
    if (alias) put_text([d stringByAppendingPathComponent:@"key_alias.tsv"], alias);
    setenv("DM_MSL_DIR", d.UTF8String, 1); setenv("DM_NVN_SHMAP", [d stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    (void)nvn_be_reload_direct_library();   // 第一次：shmap_load 首读就按新路径（回 0）；之后回 1、换表
    REQUIRE([g_shmap_path isEqualToString:[d stringByAppendingPathComponent:@"shader_map.tsv"]] && g_shmap.count == keys.count);
}
static void use_map(NSString *root, NSString *name, NSArray<NSString *> *keys) { use_map_alias(root, name, keys, nil); }
// 读档（hle_nvn.c s2a_hle_pk_load）：手写一份 gfx_progkeys.bin（格式照 s2a_hle_pk_save：n、{程序地址, 键表} × n、ns、{prog_t, 键表} × ns；键表 = 6×8 键 + 6 阶段 + ok 位，不改格式），
//   阶段 0 记 key、ok = 1；读回后看键表（prog_key）与按序号的程序快照表（nvn_prog_snap_get）两处
typedef struct { uint8_t key[6][8]; uint8_t stage[6]; uint8_t ok; } pk_mirror;
typedef struct { uint64_t p; pk_mirror k; } pk_rec_mirror;
static void restore(NSString *path, prog_t *p, uint64_t serial, const uint8_t key[8], uint8_t got_pk[8], uint8_t got_snap[8]) {
    p->nstage = 1;   // prog_key 只认程序里有的阶段
    FILE *f = fopen(path.fileSystemRepresentation, "wb"); REQUIRE(f);
    pk_rec_mirror r; memset(&r, 0, sizeof r); r.p = (uint64_t)(uintptr_t)p; memcpy(r.k.key[0], key, 8); memset(r.k.stage, 0xff, 6); r.k.ok = 1;
    uint64_t one = 1; prog_t snap; memset(&snap, 0, sizeof snap); snap.nstage = 1; snap.serial = serial;
    fwrite(&one, 8, 1, f); fwrite(&r, sizeof r, 1, f); fwrite(&one, 8, 1, f); fwrite(&snap, sizeof snap, 1, f); fwrite(&r.k, sizeof r.k, 1, f); fclose(f);
    f = fopen(path.fileSystemRepresentation, "rb"); REQUIRE(f && s2a_hle_pk_load(f) >= 0); fclose(f);
    REQUIRE(prog_key(p, 0, got_pk));
    uint8_t ks[6][8], ok = 0; REQUIRE(nvn_prog_snap_get(serial, ks, &ok, NULL) && (ok & 1)); memcpy(got_snap, ks[0], 8);
}
static void hex2(const char *h, uint8_t k[8]) { for (int i = 0; i < 8; i++) { unsigned v; sscanf(h + 2 * i, "%2x", &v); k[i] = (uint8_t)v; } }

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_nvn_keyv2.%d", getpid()]];
        setenv("DM_PSO_MANIFEST", "off", 1);   // 预热清单不在本单测范围
        for (unsigned i = 0; i < sizeof g_code; i++) g_code[i] = (uint8_t)(i * 13 + 5);
        memcpy(g_code, "\x78\x56\x34\x12", 4);
        static uint8_t A[0x880], B[0x880], C[0x880], D[0x880], E[0x880], F[0x880];
        mk_ctl(A, 0x880); memcpy(B, A, sizeof A); memcpy(C, A, sizeof A);
        for (unsigned i = 0x790; i < 0x798; i++) B[i] ^= 0x5a;
        for (unsigned i = 0x7d0; i < 0x7e8; i++) B[i] ^= 0xa5;
        C[0x100] ^= 1;
        mk_ctl(D, 0x7e0); memcpy(E, D, sizeof D); memcpy(F, D, sizeof D); E[0x792] ^= 0xff; E[0x7d8] ^= 0xff; F[0x7e4] ^= 0xff;

        // 置零规则（包表空：都取第 2 代）
        use_map(root, @"empty", @[]);
        CHECK([key_of(A) isEqual:@"e0d0ef6990987e99"], "A（own 0x880）第 2 代键 = e0d0ef6990987e99（实得 %s）", key_of(A).UTF8String);
        CHECK([key_of(B) isEqual:@"e0d0ef6990987e99"], "B 只差两段 → 与 A 同键（实得 %s）", key_of(B).UTF8String);
        CHECK([key_of(C) isEqual:@"4aa6cc1d9c43e270"], "C 差在 +0x100 → 键不同 4aa6cc1d9c43e270（实得 %s）", key_of(C).UTF8String);
        CHECK([key_of(D) isEqual:@"2729eeba92fce15e"], "D（own 0x7e0，第二段只置零到 0x7e0）= 2729eeba92fce15e（实得 %s）", key_of(D).UTF8String);
        CHECK([key_of(E) isEqual:@"2729eeba92fce15e"] && [key_of(F) isEqual:@"2729eeba92fce15e"], "E（只差 nctl 内两段）、F（差在 nctl 外）与 D 同键（实得 %s / %s）", key_of(E).UTF8String, key_of(F).UTF8String);

        // 旧包兜底
        use_map(root, @"only_v1", @[@"404d87c7549fd09c"]);
        { prog_t *p = mk_prog(A); uint8_t k[8], l[8]; REQUIRE(prog_key(p, 0, k));
          CHECK([hex8(k) isEqual:@"404d87c7549fd09c"], "① 包表只有第 1 代键 → 取 404d87c7549fd09c（实得 %s）", hex8(k).UTF8String);
          CHECK(prog_key_live(p, 0, l) && !memcmp(k, l, 8), "① 首用复核 prog_key_live 同一规则、同一个键（实得 %s）", hex8(l).UTF8String); }
        CHECK([key_of(B) isEqual:@"e0d0ef6990987e99"], "① B 的第 1 代键 1dee… 不在包表 → 取第 2 代（实得 %s）", key_of(B).UTF8String);
        use_map(root, @"only_v2", @[@"e0d0ef6990987e99"]);
        CHECK([key_of(A) isEqual:@"e0d0ef6990987e99"], "② 包表只有第 2 代键 → 取它（实得 %s）", key_of(A).UTF8String);
        use_map(root, @"none", @[@"0123456789abcdef"]);
        CHECK([key_of(A) isEqual:@"e0d0ef6990987e99"], "③ 包表两个都没有 → 第 2 代（实得 %s）", key_of(A).UTF8String);
        use_map(root, @"both", @[@"404d87c7549fd09c", @"e0d0ef6990987e99"]);
        CHECK([key_of(A) isEqual:@"e0d0ef6990987e99"], "④ 包表两个都有 → 第 2 代（实得 %s）", key_of(A).UTF8String);

        // ⑤ 兜底目录：旧版本按第 1 代键现编的产物（<键>_b.metal + 同链号、同指纹的 <键>_b.json）
        NSString *fb = [root stringByAppendingPathComponent:@"wire/0100000000010000/shaders"];
        put_text([fb stringByAppendingPathComponent:@"404d87c7549fd09c_b.metal"], @"// fixture\n");
        put_text([fb stringByAppendingPathComponent:@"404d87c7549fd09c_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"xfp\": \"00112233aabbccdd\", \"stage\": \"vs\"}\n", DMSH_CHAIN]);
        setenv("DM_MSL_FALLBACK", fb.UTF8String, 1);
        use_map(root, @"none2", @[@"0123456789abcdef"]);
        CHECK([key_of(A) isEqual:@"404d87c7549fd09c"], "⑤ 包表都没有、兜底目录有第 1 代现编产物 → 第 1 代（实得 %s）", key_of(A).UTF8String);
        unsetenv("DM_MSL_FALLBACK");

        // 读档换键（存档里是 A 的第 1 代键 404d87c7549fd09c；别名表 404d87c7549fd09c → e0d0ef6990987e99 由出包按同一份字节算，这里照规则手写）
        //   R1 包表只有第 2 代、别名表有 → 两处都换成 e0d0ef6990987e99；库名换键同口径（预热行）
        //   R2 包表本身有第 1 代（旧包，别名表也在）→ 保持 404d…    R3 包表只有第 2 代、没有别名表 → 保持 404d…
        //   反证：s2a_hle_pk_load 不规范化 → R1 两项红
        { NSString *al = @"# 第 1 代键\t第 2 代键\n404d87c7549fd09c\te0d0ef6990987e99\n", *pk = [root stringByAppendingPathComponent:@"gfx_progkeys.bin"];
          uint8_t v1[8], a[8], b[8]; hex2("404d87c7549fd09c", v1);
          use_map_alias(root, @"r1", @[@"e0d0ef6990987e99"], al); restore(pk, calloc(1, sizeof(prog_t)), 0x7e5701, v1, a, b);
          CHECK([hex8(a) isEqual:@"e0d0ef6990987e99"] && [hex8(b) isEqual:@"e0d0ef6990987e99"], "R1 读档：包只有第 2 代、别名表有 → 键表 / 快照表都换成第 2 代（实得 %s / %s）", hex8(a).UTF8String, hex8(b).UTF8String);
          CHECK([lib_name_canon(@"404d87c7549fd09c_bgv") isEqual:@"e0d0ef6990987e99_bgv"] && [lib_name_canon(@"0123456789abcdef_b") isEqual:@"0123456789abcdef_b"],
                "R1 预热行库名换键：404d…_bgv → e0d0…_bgv，别名表外的不动（实得 %s）", lib_name_canon(@"404d87c7549fd09c_bgv").UTF8String);
          use_map_alias(root, @"r2", @[@"404d87c7549fd09c", @"e0d0ef6990987e99"], al); restore(pk, calloc(1, sizeof(prog_t)), 0x7e5702, v1, a, b);
          CHECK([hex8(a) isEqual:@"404d87c7549fd09c"] && [hex8(b) isEqual:@"404d87c7549fd09c"], "R2 读档：包表本身有第 1 代 → 保持（实得 %s / %s）", hex8(a).UTF8String, hex8(b).UTF8String);
          use_map_alias(root, @"r3", @[@"e0d0ef6990987e99"], nil); restore(pk, calloc(1, sizeof(prog_t)), 0x7e5703, v1, a, b);
          CHECK([hex8(a) isEqual:@"404d87c7549fd09c"] && [hex8(b) isEqual:@"404d87c7549fd09c"], "R3 读档：没有别名表 → 保持原样（实得 %s / %s）", hex8(a).UTF8String, hex8(b).UTF8String); }

        // Switch 2 键规则不变（nvn2.h nvn2_key，本次未改）
        { static uint8_t n2[0xe0]; for (unsigned i = 0; i < sizeof n2; i++) n2[i] = (uint8_t)(i * 5 + 1);
          uint32_t m = 0x98761234u, v = 0xc9u, n = 0x40; memcpy(n2, &m, 4); memcpy(n2 + 4, &v, 4); memcpy(n2 + 0x44, &n, 4);
          uint8_t k[8]; REQUIRE(nvn2_key(n2, g_code, k));
          CHECK([hex8(k) isEqual:@"d84a694ffca1c9c9"], "Switch 2 控制段键 = d84a694ffca1c9c9（实得 %s）", hex8(k).UTF8String); }

        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        printf("%s t_nvn_keyv2：%u 项，红 %u\n", failures ? "✗" : "✓", checks, failures);
        return failures ? 1 : 0;
    }
}
