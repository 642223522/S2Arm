// 快照删除（runtime/src/snapdel.c）：期望值只看文件系统——删后三个目录都不在、占的块数归零，同名目录能重新建起来再删
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fts.h>

void s2a_snap_rmtree(const char *path); int s2a_snap_delete(const char *dir);
static int g_fail, g_ok;
#define CHECK(c, ...) do { if (c) g_ok++; else { g_fail++; printf("  不符："); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void put(const char *path, size_t n) { FILE *f = fopen(path, "wb"); if (!f) return; char b[4096]; memset(b, 7, sizeof b); while (n) { size_t k = n < sizeof b ? n : sizeof b; fwrite(b, 1, k, f); n -= k; } fclose(f); }
static long long blocks(const char *root) {   // 这棵树占的 512 字节块数（不存在为 0）
    char *av[] = {(char *)root, NULL}; FTS *fs = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL); if (!fs) return 0; long long b = 0;
    for (FTSENT *e; (e = fts_read(fs));) if (e->fts_statp && e->fts_info != FTS_DP && e->fts_info != FTS_NS) b += e->fts_statp->st_blocks;
    fts_close(fs); return b;
}
static int exists(const char *p) { struct stat st; return lstat(p, &st) == 0; }
static void make_snapshot(const char *d) {   // 仿一份快照：清单、缩略图、整帧、子目录里的内存块
    char p[1024]; mkdir(d, 0755);
    snprintf(p, sizeof p, "%s/manifest.tsv", d); put(p, 200);
    snprintf(p, sizeof p, "%s/thumb.png", d); put(p, 53 * 1024);
    snprintf(p, sizeof p, "%s/a_last.png", d); put(p, 500 * 1024);
    snprintf(p, sizeof p, "%s/mem", d); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/mem/0000.bin", d); put(p, 4 << 20);
}

int main(void) {
    char base[] = "/tmp/t_snapdel.XXXXXX"; if (!mkdtemp(base)) { printf("✗ t_snapdel：建临时目录失败\n"); return 1; }
    char snap[1100], neu[1100], old[1100], keep[1100], p[1200];
    snprintf(snap, sizeof snap, "%s/snapshot", base); snprintf(neu, sizeof neu, "%s.new", snap); snprintf(old, sizeof old, "%s.old", snap);
    snprintf(keep, sizeof keep, "%s/saves", base); mkdir(keep, 0755); snprintf(p, sizeof p, "%s/slot0", keep); put(p, 1000);

    make_snapshot(snap); make_snapshot(neu); make_snapshot(old);
    snprintf(p, sizeof p, "%s/link", snap); symlink(keep, p);   // 快照里的符号链接：只删链接，不碰它指向的存档
    long long before = blocks(base);
    CHECK(blocks(snap) > 8000, "仿出来的快照应占 >4 MB，实际 %lld 块", blocks(snap));
    CHECK(s2a_snap_delete(snap) == 0, "删除应回 0");
    CHECK(!exists(snap) && !exists(neu) && !exists(old), "删后快照目录、.new、.old 都应不在");
    CHECK(exists(keep) && blocks(keep) > 0, "符号链接指向的存档应原样还在");
    long long after = blocks(base);
    CHECK(before - after >= 3 * 8192, "空间应腾出至少三份 4 MB 内存块（%lld → %lld 块）", before, after);

    CHECK(s2a_snap_delete(snap) == 0, "再删一次（已不存在）也应回 0");
    make_snapshot(snap);   // 删完同一个位置能重新存
    snprintf(p, sizeof p, "%s/manifest.tsv", snap);
    CHECK(exists(p), "删后同一目录应能重新写入快照");
    CHECK(s2a_snap_delete(snap) == 0 && !exists(snap), "重新存的那份也能删掉");
    CHECK(s2a_snap_delete("") == -1 && s2a_snap_delete(NULL) == -1, "空路径应回 -1、什么都不删");

    s2a_snap_rmtree(base);
    printf("%s t_snapdel：%d 项通过，%d 项不符\n", g_fail ? "✗" : "✓", g_ok, g_fail);
    return g_fail != 0;
}
