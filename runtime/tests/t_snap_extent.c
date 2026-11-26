// 即时存档：后备文件「已写回、不在内存里」的页按实际分配的块找（runtime/src/snapfile.h snap_file_mark），新方法不漏旧方法找到的任何非零页。
//   期望按构造手写（见 s2a_snap_extent_selftest）：要存的非零页恰为 {1,5,6,20,30,47}、被标恰为 {1,5,6,10,11,20,47}、漏 0。
//   负对照：标记函数一页都不标（broken = 1）→ 只在文件里的 5 个非零页漏掉，自检必须不通。宿主 S2A_SNAP_EXTENT_SELFTEST=1 在真机跑同一份
#include "../src/snapfile.h"
int main(void) {
    char msg[512]; int bad = 0;
    const char *d = getenv("TMPDIR");
    int rc = s2a_snap_extent_selftest(d, 0, msg, sizeof msg);
    printf("%s 新方法：%s\n", rc ? "✗" : "✓", msg); bad += rc != 0;
    int rb = s2a_snap_extent_selftest(d, 1, msg, sizeof msg);
    printf("%s 负对照（一页都不标，应测出漏页）：%s\n", rb ? "✓" : "✗", msg); bad += rb == 0;
    printf(bad ? "✗ t_snap_extent：%d 项不符\n" : "✓ t_snap_extent：0 处不符\n", bad);
    return bad ? 1 : 0;
}
