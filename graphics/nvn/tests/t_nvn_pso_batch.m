// 管线归档批量写回（pso_archive.h par_write_batch，11-06 马车8 卡预热：一条一个文件写回 ~95 ms/条，一局写不完、退出即丢、每次启动从零编）。
//   直接包含生产 nvn_mtl.m，在真 Metal 设备上编 70 条不同的计算管线（先编一遍 = 预热），一次放进待写队列再同步跑写回。期望（按 PAR_BATCH=32 手算）：
//   ① 写出 3 个批文件（32 + 32 + 6）、batches.tsv 70 行、每行指向在的文件；② 70 个键都能经 par_archive_for 取到归档，只准命中归档地建管线（FailOnBinaryArchiveMiss）70/70 成；
//   ③ 写成计数 +70、写失败 0。反证（构建规则另编 -DPAR_BATCH=1）：批文件 70 个，① 不符
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice(); REQUIRE(g_dev);
    char tmpl[] = "/tmp/t_pso_batch.XXXXXX"; REQUIRE(mkdtemp(tmpl));
    g_par_dir = @(tmpl); g_par_have = [NSMutableSet set]; g_par_open = [NSMutableDictionary dictionary]; g_par_bmap = [NSMutableDictionary dictionary]; g_par_on = 1;
    enum { N = 70 }; NSMutableArray *descs = [NSMutableArray array], *keys = [NSMutableArray array];
    for (int i = 0; i < N; i++) {
        NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = b[i] * %d.0 + %d.0; }", i + 2, i];
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&e]; REQUIRE(lib);
        MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new]; d.computeFunction = [lib newFunctionWithName:@"k"];
        REQUIRE([g_dev newComputePipelineStateWithDescriptor:d options:0 reflection:nil error:&e]);   // 预热先编一遍
        [descs addObject:d]; [keys addObject:[NSString stringWithFormat:@"t-batch-%02d", i]];
    }
    uint64_t w0 = atomic_load(&g_par_written), f0 = atomic_load(&g_par_write_failed);
    pthread_mutex_lock(&g_par_mu); g_par_todo = [NSMutableArray array]; for (int i = 0; i < N; i++) [g_par_todo addObject:@[keys[i], descs[i]]]; g_par_writer = 1; pthread_mutex_unlock(&g_par_mu);
    par_writer();
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:g_par_dir error:nil];
    NSUInteger files = [names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'batch-' AND SELF ENDSWITH '.metalarchive'"]].count;
    NSString *idx = [NSString stringWithContentsOfFile:[g_par_dir stringByAppendingPathComponent:@"batches.tsv"] encoding:NSUTF8StringEncoding error:nil];
    NSUInteger lines = 0, dangling = 0;
    for (NSString *ln in [idx componentsSeparatedByString:@"\n"]) { NSArray *c = [ln componentsSeparatedByString:@"\t"]; if (c.count != 2) continue; lines++;
        if (![NSFileManager.defaultManager fileExistsAtPath:[g_par_dir stringByAppendingPathComponent:c[1]]]) dangling++; }
    VERIFY(files == 3 && lines == N && dangling == 0, "① 批文件 %lu 个（期望 3）、索引 %lu 行（期望 70）、指向不存在文件 %lu 行（期望 0）", (unsigned long)files, (unsigned long)lines, (unsigned long)dangling);
    int got = 0;
    for (int i = 0; i < N; i++) { id<MTLBinaryArchive> a = par_archive_for(keys[i]); if (!a) continue;
        MTLComputePipelineDescriptor *d = [descs[i] copy]; d.binaryArchives = @[a]; NSError *e = nil;
        if ([g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e]) got++; }
    VERIFY(got == N, "② 只准命中归档地建管线 %d/%d", got, N);
    VERIFY(atomic_load(&g_par_written) - w0 == N && atomic_load(&g_par_write_failed) == f0, "③ 写成 +%llu（期望 70）、写失败 +%llu（期望 0）",
           (unsigned long long)(atomic_load(&g_par_written) - w0), (unsigned long long)(atomic_load(&g_par_write_failed) - f0));
    // 11-23：写归档不再留 .writing；「不再写」只认版本先验与崩溃处理器的真崩记录（⑬ ⑭）。老版本留下的标记（被划掉 / 内存超限 / 挂起被杀都会留）起局删掉、照常写
    NSString *wflag = [g_par_dir stringByAppendingPathComponent:PAR_WRITING];
    char t3[] = "/tmp/t_pso_dead3.XXXXXX"; REQUIRE(mkdtemp(t3));   // 全机真崩标记放临时目录：本段起局判定只看它
    snprintf(g_par_dead_path, sizeof g_par_dead_path, "%s/pso_archive_dead.txt", t3); snprintf(g_par_os_key, sizeof g_par_os_key, "Version 99.1 (Build T1)");
    VERIFY(![NSFileManager.defaultManager fileExistsAtPath:wflag], "④ 写完 70 条：归档目录里没有 .writing 标记（新版不留）");
    // ⑤ 反证（原判据）：老版本写到一半被杀留下的标记（带版本行，原先据此从此不写）→ 起局删掉、照常写
    REQUIRE(([@"s2a-pso-writing 2 pid=1 batch-x\n" writeToFile:wflag atomically:NO encoding:NSUTF8StringEncoding error:nil]));
    par_check_dead_write();
    VERIFY(g_par_nowrite == 0 && ![NSFileManager.defaultManager fileExistsAtPath:wflag], "⑤ 老版本被杀留下的 .writing（没有真崩记录）：标记删掉、照常写（nowrite=%d，应 0）", g_par_nowrite);
    REQUIRE([@"batch-x" writeToFile:wflag atomically:NO encoding:NSUTF8StringEncoding error:nil]);   // 更老的无版本行标记
    par_check_dead_write();
    VERIFY(g_par_nowrite == 0 && ![NSFileManager.defaultManager fileExistsAtPath:wflag], "⑦ 更老的无版本行标记：同样删掉、照常写（nowrite=%d）", g_par_nowrite);
    // ⑥ 真崩照停：写归档时崩（崩溃处理器在 g_par_in_write 下记全机标记）→ 起局不再写、par_note 不进待写队列
    g_par_in_write = 1; s2a_pso_archive_crash_note(); g_par_in_write = 0;
    par_check_dead_write();
    VERIFY(g_par_nowrite == 1, "⑥a 写归档时真崩过（崩溃处理器记了本系统版本）→ 起局不再写（nowrite=%d，应 1）", g_par_nowrite);
    pthread_mutex_lock(&g_par_mu); NSUInteger before = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    par_note(@"t-after-dead-write", descs[0]);
    pthread_mutex_lock(&g_par_mu); NSUInteger after = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    VERIFY(after == before, "⑥b 不再写时 par_note 不进待写队列（%lu → %lu）", (unsigned long)before, (unsigned long)after);
    s2a_pso_archive_exit(); par_check_dead_write();
    VERIFY(g_par_nowrite == 1, "⑫ 真崩判定不被正常收局清掉：收局后再起局仍不再写（nowrite=%d）", g_par_nowrite);
    unlink(g_par_dead_path); g_par_nowrite = 0; atomic_store(&g_par_closing, 0);
    // ⑧ 一批写到一半正常收局（#618）：不留标记，下一局照常写
    s2a_pso_archive_exit();
    VERIFY(![NSFileManager.defaultManager fileExistsAtPath:wflag], "⑧ 写到一半正常收局：没有标记");
    par_check_dead_write();
    VERIFY(g_par_nowrite == 0, "⑨ 下一局起局：照常写（nowrite=%d）", g_par_nowrite);
    // 收局之后写线程再起一批（与收局赛跑输了的那一侧）：不写、不进队列
    uint64_t w1 = atomic_load(&g_par_written);
    par_write_batch(@[@[@"t-after-exit", descs[1]]]);
    VERIFY(![NSFileManager.defaultManager fileExistsAtPath:wflag] && atomic_load(&g_par_written) == w1, "⑩ 收局后起的一批：不留标记、不写（写成 +%llu）", (unsigned long long)(atomic_load(&g_par_written) - w1));
    pthread_mutex_lock(&g_par_mu); before = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    par_note(@"t-after-exit-note", descs[2]);
    pthread_mutex_lock(&g_par_mu); after = g_par_todo.count; pthread_mutex_unlock(&g_par_mu);
    VERIFY(after == before, "⑪ 收局后 par_note 不进待写队列（%lu → %lu）", (unsigned long)before, (unsigned long)after);
    g_par_dead_path[0] = 0; { char cmd[256]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", t3); system(cmd); }
    [NSFileManager.defaultManager removeItemAtPath:g_par_dir error:nil];
    // ⑬ #756 版本先验（期望按玩家诊断定的区间手写）：iOS 18.0–18.3 不写；18.4、17.7、26.0 与非 iOS 的 18.2 照写
    VERIFY(par_os_gate(1, 18, 0) && par_os_gate(1, 18, 3) && !par_os_gate(1, 18, 4) && !par_os_gate(1, 17, 7) && !par_os_gate(1, 26, 0) && !par_os_gate(0, 18, 2),
           "⑬ 版本先验：iOS 18.0 / 18.3 不写，18.4 / 17.7 / 26.0 / 非 iOS 18.2 照写");
    // ⑭ 全机学习：崩溃线程不在写归档时崩溃钩子不记；在写时记本系统版本串 → 同机任一款（同一标记文件）起局都不写；系统版本串变了（升级）不再命中
    {
        char t2[] = "/tmp/t_pso_dead.XXXXXX"; REQUIRE(mkdtemp(t2));
        snprintf(g_par_dead_path, sizeof g_par_dead_path, "%s/pso_archive_dead.txt", t2);
        snprintf(g_par_os_key, sizeof g_par_os_key, "Version 18.9 (Build 22Z1)");
        g_par_in_write = 0; s2a_pso_archive_crash_note();
        int before = par_gate_or_learned(1, 26, 1);
        g_par_in_write = 1; s2a_pso_archive_crash_note(); g_par_in_write = 0;
        int learned = par_gate_or_learned(1, 26, 1);
        snprintf(g_par_os_key, sizeof g_par_os_key, "Version 18.10 (Build 22Z9)");
        int after_upgrade = par_gate_or_learned(1, 26, 1);
        VERIFY(!before && learned && !after_upgrade, "⑭ 全机学习：不在写时崩不记（命中 %d，应 0）、在写时崩后同系统版本不写（%d，应 1）、升级后重判（%d，应 0）", before, learned, after_upgrade);
        g_par_dead_path[0] = 0; char cmd[256]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", t2); system(cmd);
    }
    // ⑮ 真崩后隔几局重试（11-23 D-KDM4）：期望按规则手写——崩 1 次：停 3 局（1 1 1）、第 4 局重试写（0）；下一局没新崩 → 清记录、照写（0），标记里本版本 0 行。
    //   再崩：重试局里又崩（追加第 2 行）→ 停 6 局再重试；别的系统版本不受影响
    {
        char t4[] = "/tmp/t_pso_retry.XXXXXX"; REQUIRE(mkdtemp(t4));
        snprintf(g_par_dead_path, sizeof g_par_dead_path, "%s/pso_archive_dead.txt", t4);
        snprintf(g_par_os_key, sizeof g_par_os_key, "Version 27.2.1 (Build 24B91034)");
        g_par_in_write = 1; s2a_pso_archive_crash_note(); g_par_in_write = 0;   // 真崩 1 次
        char seq[32] = ""; for (int i = 0; i < 5; i++) seq[i] = (char)('0' + par_gate_or_learned(1, 27, 2));
        int left = par_dead_global_count();
        VERIFY(!strcmp(seq, "11100") && left == 0, "⑮ 崩 1 次：起局序列 %s（应 11100：停 3 局、第 4 局重试、重试没崩后照写），之后本版本记录 %d 行（应 0）", seq, left);
        g_par_in_write = 1; s2a_pso_archive_crash_note(); g_par_in_write = 0;   // 又崩 1 次（记录已清，重新计 1 次）
        for (int i = 0; i < 3; i++) (void)par_gate_or_learned(1, 27, 2);         // 停 3 局
        int retry = par_gate_or_learned(1, 27, 2);                              // 第 4 局重试
        g_par_in_write = 1; s2a_pso_archive_crash_note(); g_par_in_write = 0;   // 重试那局又崩 → 共 2 次
        char seq2[32] = ""; for (int i = 0; i < 7; i++) seq2[i] = (char)('0' + par_gate_or_learned(1, 27, 2));
        snprintf(g_par_os_key, sizeof g_par_os_key, "Version 27.3 (Build 24C1)"); int other = par_gate_or_learned(1, 27, 3);
        VERIFY(retry == 0 && !strcmp(seq2, "1111110") && other == 0, "⑮ 重试局又崩：重试局 %d（应 0），之后序列 %s（应 1111110：间隔翻倍停 6 局再重试），别的系统版本 %d（应 0）", retry, seq2, other);
        g_par_dead_path[0] = 0; char cmd[256]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", t4); system(cmd);
    }
    if (failures) { printf("✗ t_nvn_pso_batch：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_pso_batch：%u 项全过（70 条管线写成 3 个批文件，按键全部取回；老版本被杀留下的标记不再停写、真崩照停；正常收局不留标记）\n", checks); return 0;
} }
