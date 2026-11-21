// 即时快照的删除（0.6.0）：游戏库 / 游戏里长按「删除这一刻」删掉这一款的快照，空间真腾出来。
//   快照目录连同缩略图、清单、内存块一起删；存到一半留下的 <目录>.new、换上新快照时留下的 <目录>.old 也一并删。
//   删整棵目录的 s2a_snap_rmtree 也给存档引擎（snapshot.c）删临时 / 旧目录用，同一份实现。不依赖引擎其余部分，单测只链本文件
#include <fts.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

// 删整棵目录；不存在不算错；不跟符号链接（链接本身删掉，指向的东西不碰）
void s2a_snap_rmtree(const char *path) {
    char *av[] = {(char *)path, NULL}; FTS *fs = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL); if (!fs) return;
    for (FTSENT *e; (e = fts_read(fs));) { if (e->fts_info == FTS_DP) rmdir(e->fts_path); else if (e->fts_info == FTS_F || e->fts_info == FTS_SL || e->fts_info == FTS_SLNONE || e->fts_info == FTS_DEFAULT) unlink(e->fts_path); }
    fts_close(fs);
}

// 引擎正在存档时为 1（snapshot.c）；单测只链本文件、没有它 = 当作没在存
// 弱链接[host]：s2a_snap_busy（runtime/src/snapshot.c 提供；snapdel 单测只链本文件）
int s2a_snap_busy(void) __attribute__((weak_import));
// 删掉一款的快照：0 删干净了（三个目录都不在了）；-2 引擎正在存（存到一半往 <目录>.new 写、最后挪名换上，这时删会和它互相踩），不删；
//   -1 参数不对（相对路径也不收：调用方都给 s2a_snap_dir_for 的绝对路径，相对路径会按进程当前目录去删）或还有删不掉的
int s2a_snap_delete(const char *dir) {
    if (!dir || dir[0] != '/') return -1;
    if (s2a_snap_busy && s2a_snap_busy()) return -2;
    char p[2100]; struct stat st; int left = 0;
    const char *suffix[] = {"", ".new", ".old"};
    for (int i = 0; i < 3; i++) {
        if (snprintf(p, sizeof p, "%s%s", dir, suffix[i]) >= (int)sizeof p) return -1;
        s2a_snap_rmtree(p); left |= lstat(p, &st) == 0;
    }
    return left ? -1 : 0;
}
