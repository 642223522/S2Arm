// 即时存档（苹果端缺省开、S2A_SNAP_MODE=0 关，见 snapsw.c；恢复局 S2A_SNAP_RESTORE）：游玩中把游戏冻结在「门里」安全点，存下游戏内存 + 内存账 + 内核账（+ 后续阶段的服务 / 音频 / 图形），退出进程；
//   新进程按快照恢复。设计见 ~/.../side-session-notes/即时存档_实现设计_1116.md。
// 开关（缺省全关，不影响现有路径）：
//   存档模式（缺省；S2A_SNAP_MODE=0 关）起局：游戏线程 TLS / 线程对象落进窗口 arena（地址随快照走）
//   S2A_SNAP_AT=<秒>     起局后到点存一次快照并退出进程；S2A_SNAP_DIR=<目录> 快照写到这里（必须是空目录或不存在）
//   S2A_SNAP_RESTORE=<目录>  从快照恢复：先核清单（构建号 / 宿主二进制 / 程序号 / 窗口 / 布局 / 存档目录），任何一项不符打红拒绝、不碰存档直接退出
#include "native.h"
#include "imgpack.h"
#include "s2a_docs.h"
#include "snapfmt.h"
#include <limits.h>
#include <compression.h>
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/clonefile.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

const s2a_layout *s2a_layout_get(void);
uint64_t s2a_npdm_program_id(void);
int s2a_snap_svcmem_save(FILE *f);
int s2a_snap_shared_ranges(uint64_t *b, uint64_t *n, int max);
int s2a_snap_freeze(int timeout_ms, int *nthr, int *nst);
int s2a_snap_kernel_save(FILE *f);
int s2a_snap_hlog_save(FILE *f);
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapLogSave（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapReplay（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapAudioSave（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapAudioRestore（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapSessionReset（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapDataRoot（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：S2A_SnapAudioFp（服务层 C#（services/S2A.Services/SnapLog.cs）提供；不链 C# 的构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
int S2A_SnapLogSave(const char *path) __attribute__((weak_import));
int S2A_SnapReplay(const char *path, uint64_t scratch, uint64_t size) __attribute__((weak_import));
int S2A_SnapAudioSave(const char *path) __attribute__((weak_import));
int S2A_SnapAudioRestore(const char *path) __attribute__((weak_import));
int s2a_snap_svcmem_load(FILE *f);
void s2a_snap_svcmem_perms(void);
int s2a_snap_svcmem_shared(void);
int s2a_snap_hlog_load(FILE *f);
int s2a_snap_skip_cs(uint32_t h, uint32_t kind);
int s2a_snap_kernel_load(FILE *f, int (*skip)(uint32_t, uint32_t));
int s2a_snap_replay_prelude(void);
int s2a_snap_kernel_post(void);
int s2a_snap_defer_finish(void);
int s2a_snap_hostslots_reapply(void);
// 弱链接[host,ios,touchtest]：nvn_snap_save（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_snap_restore（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_be_drain（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_snap_grab（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_snap_proc（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：hle_snap_fps（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_snap_fps（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn2_codec_snap_fps（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn2_snap_fps（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
// 弱链接[host,ios,touchtest]：nvn_snap_redump（直连图形层 graphics/nvn/gfx/nvn 提供；不链图形库的宿主构建没有，没有就不存 / 不恢复图形状态）
int nvn_snap_save(const char *dir) __attribute__((weak_import));
int nvn_snap_restore(const char *dir) __attribute__((weak_import));
int s2a_snap_hostslots_save(FILE *f);
size_t s2a_snap_hostmap(FILE *f, uint64_t **from, uint64_t **to);
int s2a_snap_threads_start(void);
void s2a_snap_unfreeze(void);
void nvn_be_drain(void) __attribute__((weak_import));
int nvn_snap_grab(const char *path) __attribute__((weak_import));

static double now_s(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
void s2a_snap_live_set(int on);   // snapsw.c：恢复完成 / 进程内重建时改「正在记日志」
void s2a_snap_hlog_continue(void);   // thread.c：快照里的句柄日志接过来当开头
// 进程内重建开新一局（开着快照才有效）：日志从头记；要恢复时先不记，恢复完成接上快照日志后再记（同冷启动的恢复局）
void s2a_snap_kernel_fresh(void);   // thread.c
int S2A_SnapSessionReset(int restoring) __attribute__((weak_import));   // SnapLog.cs：服务层请求日志清空、按 restoring 设记不记
void s2a_snap_session_fresh(int restoring) {
    if (!s2a_snap_mode()) return;
    s2a_snap_kernel_fresh();
    s2a_snap_live_set(s2a_snap_saving() && !restoring);
    if (S2A_SnapSessionReset) S2A_SnapSessionReset(restoring);
    LOG("即时存档：进程内重建，日志从头记%s", restoring ? "（这一局按快照恢复：恢复完成后接上快照日志）" : "");
}
static void snap_live_after_restore(void) { if (!s2a_snap_saving()) return; s2a_snap_hlog_continue(); s2a_snap_live_set(1); LOG("即时存档：恢复局接着记日志（接上快照里的请求 / 句柄日志），之后还能再存"); }

// ---------- 哈希 ----------
static void hex(const uint8_t *d, int n, char *out) { for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", d[i]); }
static int sha_file(const char *p, CC_SHA256_CTX *c) {
    int fd = open(p, O_RDONLY); if (fd < 0) return -1;
    enum { BUF = 1 << 20 }; uint8_t *buf = malloc(BUF); ssize_t n = -1;   // 不用线程局部变量：本镜像的线程局部变量按镜像整块分配，开关关着也会给每条线程多分 1 MiB
    if (buf) while ((n = read(fd, buf, BUF)) > 0) CC_SHA256_Update(c, buf, (CC_LONG)n);
    free(buf); close(fd); return n < 0 ? -1 : 0;
}
// 存档目录哈希：按路径排序逐个文件（相对路径 + 内容）。目录不在 = "无"
static int cmpstr(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static void tree_files(const char *root, const char *rel, char ***v, int *n, int *cap) {
    char p[2048]; snprintf(p, sizeof p, "%s/%s", root, rel); DIR *d = opendir(p); if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char r[2048]; snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", e->d_name);
        char q[4096]; snprintf(q, sizeof q, "%s/%s", root, r); struct stat st; if (lstat(q, &st)) continue;
        if (S_ISDIR(st.st_mode)) tree_files(root, r, v, n, cap);
        else if (S_ISREG(st.st_mode)) { if (*n == *cap) { *cap = *cap ? *cap * 2 : 64; *v = realloc(*v, sizeof **v * (size_t)*cap); } (*v)[(*n)++] = strdup(r); }
    }
    closedir(d);
}
// committed = 1：只算已提交部分（<存档号>/0/…，判「快照之后玩家又存过档」）；0：整棵树（工作副本、附加数据都算，判「恢复后与快照时一致」）
static int committed_path(const char *rel) { const char *s1 = strchr(rel, '/'); return s1 && s1[1] == '0' && s1[2] == '/'; }
int S2A_SnapDataRoot(char *buf, int n) __attribute__((weak_import));   // 服务层实际用的 Ryujinx 数据根（SnapLog.cs）；服务层起来之前 / 没链服务层时退回 S2A_RYU_DATA
// 数据根写进清单时去掉文档根前缀（「@docs/…」）：iPhone 重装 App 后数据容器路径会换（重装后容器目录名会变，Documents 内容随迁），绝对路径不能跨装机比
static void root_portable(const char *abs, char *out, size_t n) {
    char d[2048], rd[PATH_MAX], ra[PATH_MAX]; s2a_docs_root(d, sizeof d);
    const char *pa = realpath(abs, ra) ? ra : abs, *pd = realpath(d, rd) ? rd : d; size_t k = strlen(pd);
    if (!strncmp(pa, pd, k) && (pa[k] == '/' || !pa[k])) { snprintf(out, n, "@docs%s", pa + k); return; }
    const char *h = getenv("HOME"); char rh[PATH_MAX]; const char *ph = h && realpath(h, rh) ? rh : h; size_t kh = ph ? strlen(ph) : 0;
    if (kh && !strncmp(pa, ph, kh) && (pa[kh] == '/' || !pa[kh])) snprintf(out, n, "@home%s", pa + kh); else snprintf(out, n, "%s", pa);
}
static void root_expand(const char *v, char *out, size_t n) {
    if (!strncmp(v, "@docs", 5)) { char d[2048]; s2a_docs_root(d, sizeof d); snprintf(out, n, "%s%s", d, v + 5); }
    else if (!strncmp(v, "@home", 5) && getenv("HOME")) snprintf(out, n, "%s%s", getenv("HOME"), v + 5);
    else snprintf(out, n, "%s", v);
}
static char g_root_hint[2048], g_root_hint_v[2048];   // 展开后的路径 / 清单里的原值（可移植形式）   // 恢复校验时服务层还没起：用快照清单里记的数据根（存档时服务层实际用的），服务层起来后再核两者相同
static void save_root(char *root, size_t n) {
    char d[2048]; const char *ryu = getenv("S2A_RYU_DATA");
    if (S2A_SnapDataRoot && S2A_SnapDataRoot(d, sizeof d) > 0) ryu = d;
    else if (g_root_hint[0]) ryu = g_root_hint;
    snprintf(root, n, "%s/bis/user/save", ryu && *ryu ? ryu : "/nonexistent");
}
static void tree_hash(const char *root, int committed, char *out, int *nfiles) {
    char **v = NULL; int n = 0, cap = 0; tree_files(root, "", &v, &n, &cap);
    qsort(v, (size_t)n, sizeof *v, cmpstr);
    CC_SHA256_CTX c; CC_SHA256_Init(&c); int k = 0;
    for (int i = 0; i < n; i++) { if (!committed || committed_path(v[i])) { CC_SHA256_Update(&c, v[i], (CC_LONG)strlen(v[i]) + 1); char q[4096]; snprintf(q, sizeof q, "%s/%s", root, v[i]); sha_file(q, &c); k++; } free(v[i]); }
    free(v); uint8_t d[32]; CC_SHA256_Final(d, &c); hex(d, 32, out); *nfiles = k;
}
static void save_dir_hash(char *out, int *nfiles) { char root[2048]; save_root(root, sizeof root); tree_hash(root, 1, out, nfiles); }   // 玩家游戏存档的已提交部分（系统存档每次开局服务层都会提交，不算）
static void save_full_hash(char *out, int *nfiles) { char root[2048]; save_root(root, sizeof root); tree_hash(root, 0, out, nfiles); }
// 恢复：把快照里的整棵存档树原地写回（同一文件就地截断重写，服务层打开着的文件句柄不失效；快照里没有的删掉）
static int save_tree_put(const char *src) {
    char root[2048]; save_root(root, sizeof root);
    char **v = NULL; int n = 0, cap = 0, e = 0, w = 0, del = 0; tree_files(src, "", &v, &n, &cap);
    static uint8_t buf[1 << 20];
    for (int i = 0; i < n; i++) {
        char a[4096], b[4096]; snprintf(a, sizeof a, "%s/%s", src, v[i]); snprintf(b, sizeof b, "%s/%s", root, v[i]);
        for (char *q = b + strlen(root) + 1; (q = strchr(q, '/')); q++) { *q = 0; mkdir(b, 0755); *q = '/'; }
        int fi = open(a, O_RDONLY), fo = open(b, O_WRONLY | O_CREAT | O_TRUNC, 0644); ssize_t r;
        if (fi < 0 || fo < 0) e++; else while ((r = read(fi, buf, sizeof buf)) > 0) if (write(fo, buf, (size_t)r) != r) { e++; break; }
        if (fi >= 0) close(fi); if (fo >= 0) { fsync(fo); close(fo); } w++;
    }
    char **cur = NULL; int nc = 0, cc = 0; tree_files(root, "", &cur, &nc, &cc);
    for (int i = 0; i < nc; i++) { int hit = 0; for (int j = 0; j < n && !hit; j++) hit = !strcmp(cur[i], v[j]); if (!hit) { char b[4096]; snprintf(b, sizeof b, "%s/%s", root, cur[i]); unlink(b); del++; } free(cur[i]); }
    for (int i = 0; i < n; i++) free(v[i]); free(v); free(cur);
    LOG("%s即时存档恢复：存档树写回 %d 个文件、删多余 %d 个", e ? "【红】" : "", w, del); return e ? -1 : 0;
}
static char g_exe_hash[65];
static void exe_hash(void) {
    char p[4096]; uint32_t n = sizeof p; if (_NSGetExecutablePath(p, &n)) { strcpy(g_exe_hash, "?"); return; }
    CC_SHA256_CTX c; CC_SHA256_Init(&c); if (sha_file(p, &c)) { strcpy(g_exe_hash, "?"); return; }
    uint8_t d[32]; CC_SHA256_Final(d, &c); hex(d, 32, g_exe_hash);
}
static void layout_hash(const s2a_layout *l, char *out) { uint8_t d[32]; CC_SHA256(l, (CC_LONG)sizeof *l, d); hex(d, 32, out); }

// ---------- 清单 ----------
typedef struct { char build[80], exe[65], prog[24], win[64], layout[65], save[80]; int save_n; } snap_id;
static void current_id(snap_id *id) {
    memset(id, 0, sizeof *id);
    snprintf(id->build, sizeof id->build, "%s", s2a_main_build_id());
    if (!g_exe_hash[0]) exe_hash();
    snprintf(id->exe, sizeof id->exe, "%s", g_exe_hash);
    snprintf(id->prog, sizeof id->prog, "%016llx", (unsigned long long)s2a_npdm_program_id());
    uint64_t b, s; s2a_window_get(&b, &s); snprintf(id->win, sizeof id->win, "%#llx+%#llx", (unsigned long long)b, (unsigned long long)s);
    layout_hash(s2a_layout_get(), id->layout);
    save_dir_hash(id->save, &id->save_n);
}

// ---------- 交给游戏的宿主指针（导入槽、NVN 取函数地址…）：恢复时按主程序地址随机化偏移差平移 ----------
// 交给游戏的宿主地址（游戏会把它拷进自己的数据：分配器函数表、NVN 函数表等）。跨版本恢复时这些地址全变，按「身份」换算，不按整体偏移差：
//   身份 = slot:<游戏里的槽地址>（装载时写进 GOT / 重定位槽的值，新版装载器在同一槽写自己的值）、nvn:<函数名>:<c|f>（NVN 取函数地址，计数 / 快速两种 thunk）。
//   一个值登记一次（先到的身份为准；同值多身份解析出的新值必然相同）。只在存档模式下登记（关着不分配、不记）
typedef struct { uint64_t v; char id[128]; } ho_ent;   // 身份串够放最长的 NVN 函数名（70 多字符）
static pthread_mutex_t g_ho_mu = PTHREAD_MUTEX_INITIALIZER; static ho_ent *g_ho; static size_t g_nho, g_capho;   // 开放寻址，键 = v
void s2a_snap_handout_id(uint64_t v, const char *id) {
    if (!v || !id || !s2a_snap_mode()) return;
    pthread_mutex_lock(&g_ho_mu);
    if (g_nho * 2 >= g_capho) {
        size_t nc = g_capho ? g_capho * 2 : 4096; ho_ent *n = calloc(nc, sizeof *n);
        for (size_t i = 0; i < g_capho; i++) if (g_ho[i].v) { size_t j = (g_ho[i].v * 0x9E3779B97F4A7C15ull) >> 40 & (nc - 1); while (n[j].v) j = (j + 1) & (nc - 1); n[j] = g_ho[i]; }
        free(g_ho); g_ho = n; g_capho = nc; }
    size_t j = (v * 0x9E3779B97F4A7C15ull) >> 40 & (g_capho - 1);
    while (g_ho[j].v && g_ho[j].v != v) j = (j + 1) & (g_capho - 1);
    if (!g_ho[j].v) { g_ho[j].v = v; snprintf(g_ho[j].id, sizeof g_ho[j].id, "%s", id); g_nho++; }
    pthread_mutex_unlock(&g_ho_mu);
}
// 交给游戏的宿主数据段（游戏拿着指向它内部的指针，如视频同步点槽里的系统事件结构）：按名字登记，恢复时段内的值按「同名段的新起点 + 段内偏移」换算
static struct { uint64_t lo, n; char name[32]; } g_hor[64]; static int g_nhor;
void s2a_snap_handout_range(uint64_t lo, uint64_t n, const char *name) {
    if (!s2a_snap_mode()) return;
    pthread_mutex_lock(&g_ho_mu); if (g_nhor < 64) { g_hor[g_nhor].lo = lo; g_hor[g_nhor].n = n; snprintf(g_hor[g_nhor].name, sizeof g_hor[0].name, "%s", name); g_nhor++; } pthread_mutex_unlock(&g_ho_mu);
}
// 交给游戏的宿主内存块（本进程里的拷贝，游戏把它的地址存进自己的数据）：如 Switch 2 程序对象里的控制段自持拷贝（graphics/nvn/gfx/nvn/hle_nvn.c ctl_intern，
//   11-18 iPhone 大金刚：快照时刻有「设过着色器、还没首用」的程序，恢复后程序对象里是 A 进程的堆地址，首用读它 SIGSEGV）。
//   按内容身份登记：身份 = blob:<长度>:<SHA-256 前 20 字节>，值 = 块地址；存档时块内容随快照存（blob.bin），恢复时按身份在本进程重建一份（不释放），
//   游戏内存里的旧地址照交出指针换算成新地址。只收登记后内容不再改的块（恢复时按内容核身份，改过的块解析不了、点名报红）
typedef struct { uint64_t p; uint32_t n; } blob_ent; static blob_ent *g_blob; static size_t g_nblob, g_capblob;
static void blob_id(const void *p, uint32_t n, char *id, size_t cap) {
    uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(p, n, md); int k = snprintf(id, cap, "blob:%u:", n);
    for (int i = 0; i < 20 && k > 0 && (size_t)k < cap; i++) k += snprintf(id + k, cap - (size_t)k, "%02x", md[i]);
}
void s2a_snap_handout_blob(const void *p, uint32_t n) {
    if (!p || !n || !s2a_snap_mode()) return;
    char id[128]; blob_id(p, n, id, sizeof id); s2a_snap_handout_id((uint64_t)(uintptr_t)p, id);
    pthread_mutex_lock(&g_ho_mu);
    if (g_nblob == g_capblob) { g_capblob = g_capblob ? g_capblob * 2 : 1024; g_blob = realloc(g_blob, sizeof *g_blob * g_capblob); }
    g_blob[g_nblob++] = (blob_ent){(uint64_t)(uintptr_t)p, n};
    pthread_mutex_unlock(&g_ho_mu);
}
#define BL_MAGIC 0x31304C42u   // "BL01"：块数；每块 [长度 u32][内容]
static int blob_save(FILE *f) {
    pthread_mutex_lock(&g_ho_mu); uint32_t mg = BL_MAGIC; uint64_t n = g_nblob, bytes = 0; int e = fwrite(&mg, 4, 1, f) != 1 || fwrite(&n, 8, 1, f) != 1;
    for (size_t i = 0; i < g_nblob && !e; i++) { e |= fwrite(&g_blob[i].n, 4, 1, f) != 1 || fwrite((const void *)(uintptr_t)g_blob[i].p, 1, g_blob[i].n, f) != g_blob[i].n; bytes += g_blob[i].n; }
    pthread_mutex_unlock(&g_ho_mu);
    if (n) LOG("即时存档：交给游戏的宿主内存块 %llu 块 %.1f KB（按内容身份，恢复时重建）", (unsigned long long)n, bytes / 1024.0);
    return e ? -1 : 0;
}
// 恢复：第一次按 blob: 身份解析时读 blob.bin，每块在本进程拷一份、按身份排序；之后二分查
typedef struct { char id[64]; uint64_t p; } blob_res; static blob_res *g_blres; static size_t g_nblres; static int g_blob_loaded; static const char *g_blob_dir;
static int blres_cmp(const void *a, const void *b) { return strcmp(((const blob_res *)a)->id, ((const blob_res *)b)->id); }
static FILE *open_in(const char *dir, const char *name, const char *mode);
static uint64_t blob_resolve(const char *id) {
    if (!g_blob_loaded) { g_blob_loaded = 1; FILE *f = g_blob_dir ? open_in(g_blob_dir, "blob.bin", "rb") : NULL; uint32_t mg = 0; uint64_t n = 0;
        if (!f || fread(&mg, 4, 1, f) != 1 || mg != BL_MAGIC || fread(&n, 8, 1, f) != 1) LOG("【红】即时存档恢复：快照缺宿主内存块表（blob.bin）");
        else { g_blres = calloc(n ? n : 1, sizeof *g_blres);
            for (uint64_t i = 0; i < n; i++) { uint32_t len = 0; if (fread(&len, 4, 1, f) != 1 || !len || len > (64u << 20)) break; void *c = malloc(len);
                if (!c || fread(c, 1, len, f) != len) { free(c); break; }
                blob_id(c, len, g_blres[g_nblres].id, sizeof g_blres[0].id); g_blres[g_nblres++].p = (uint64_t)(uintptr_t)c; }
            qsort(g_blres, g_nblres, sizeof *g_blres, blres_cmp);
            LOG("即时存档恢复：宿主内存块 %zu 块按内容重建（表里 %llu 块）", g_nblres, (unsigned long long)n); }
        if (f) fclose(f); }
    blob_res k; snprintf(k.id, sizeof k.id, "%s", id); const blob_res *r = bsearch(&k, g_blres, g_nblres, sizeof *g_blres, blres_cmp);
    return r ? r->p : 0;
}
#define HO_MAGIC 0x33304F48u   // "HO03"：值 + 身份；段 = 名字 + 起点 + 长度
int s2a_snap_hostslot_at(size_t i, uint64_t *where, uint64_t *v);   // loader.c
// 弱链接[host,ios,touchtest]：gl_snap_handout_now（GL 出图层 egl.m 提供：映射着的缓冲指针在存档这一刻登记；不链图形库的宿主构建没有）
void gl_snap_handout_now(void) __attribute__((weak_import));
static int handout_save(FILE *f) {
    if (gl_snap_handout_now) gl_snap_handout_now();
    { uint64_t w, v; char id[40];   // 装载器写进游戏内存的宿主地址槽：按「slot:<槽址>」登记身份（恢复时按本进程同一个槽的值换算）
      for (size_t i = 0; !s2a_snap_hostslot_at(i, &w, &v); i++) { snprintf(id, sizeof id, "slot:%llx", (unsigned long long)w); s2a_snap_handout_id(v, id); } }
    pthread_mutex_lock(&g_ho_mu); uint32_t mg = HO_MAGIC; uint64_t n = g_nho; int e = fwrite(&mg, 4, 1, f) != 1 || fwrite(&n, 8, 1, f) != 1;
    for (size_t i = 0; i < g_capho && !e; i++) if (g_ho[i].v) e |= fwrite(&g_ho[i], sizeof g_ho[i], 1, f) != 1;
    e |= fwrite(&g_nhor, sizeof g_nhor, 1, f) != 1 || fwrite(g_hor, sizeof g_hor[0], (size_t)g_nhor, f) != (size_t)g_nhor;
    pthread_mutex_unlock(&g_ho_mu); LOG("即时存档：交给游戏的宿主指针 %llu 个、宿主数据段 %d 段", (unsigned long long)n, g_nhor); return e ? -1 : 0;
}
// 恢复：身份 → 本进程的值（0 = 解析不了）
uint64_t s2a_snap_hostslot_value(uint64_t where);   // loader.c
uint64_t nvn_snap_proc(const char *name, int counting) __attribute__((weak_import));   // hle_nvn.c
// 弱链接[host,ios,touchtest]：gl_snap_resolve（GL 出图层 graphics/nvn/gfx/gl/egl.m 提供：表面 / 上下文句柄、取函数地址、字符串、映射指针按身份换算；不链图形库的宿主构建没有）
uint64_t gl_snap_resolve(const char *id) __attribute__((weak_import));
// 弱链接[host,ios,touchtest]：vk_snap_resolve（Vulkan 出图层 graphics/nvn/gfx/vk/vk_snap.inc 提供：取函数地址按身份换算；不链图形库的宿主构建没有）
uint64_t vk_snap_resolve(const char *id) __attribute__((weak_import));
static uint64_t handout_resolve(const char *id) {
    if (!strncmp(id, "blob:", 5)) return blob_resolve(id);
    if (!strncmp(id, "gl:", 3)) return gl_snap_resolve ? gl_snap_resolve(id) : 0;
    if (!strncmp(id, "vk:", 3)) return vk_snap_resolve ? vk_snap_resolve(id) : 0;
    if (!strncmp(id, "slot:", 5)) return s2a_snap_hostslot_value(strtoull(id + 5, NULL, 16));
    if (!strncmp(id, "nvn:", 4) && nvn_snap_proc) { char nm[128]; snprintf(nm, sizeof nm, "%s", id + 4); char *c = strrchr(nm, ':'); if (!c) return 0; int cnt = c[1] == 'c'; *c = 0; return nvn_snap_proc(nm, cnt); }
    return 0;
}

// ---------- 游戏内存页 ----------
// 记录：[地址 u64][原长 u64][压缩长 u64（== 原长表示未压缩）][数据]；末尾地址 0 结束
typedef struct { uint64_t a, n; } span_t;
static int in_ranges(uint64_t a, const uint64_t *b, const uint64_t *n, int k) { for (int i = 0; i < k; i++) if (a >= b[i] && a < b[i] + n[i]) return 1; return 0; }
static int page_zero(const uint8_t *p) { const uint64_t *q = (const uint64_t *)p; for (size_t i = 0; i < 0x4000 / 8; i++) if (q[i]) return 0; return 1; }
static int g_dump_noread; static uint64_t g_dump_noread_b;
static int dump_mem(FILE *f, uint64_t *raw_out, uint64_t *comp_out, int *nreg) {
    uint64_t base, size; s2a_window_get(&base, &size); const uint64_t pg = 0x4000, CH = 8ull << 20;
    uint64_t sb[1024], sn[1024]; int ns = s2a_snap_shared_ranges(sb, sn, 1023);
    { int s2a_far_shadow_in_window(uint64_t *, uint64_t *); uint64_t fl, fh; if (s2a_far_shadow_in_window(&fl, &fh)) { sb[ns] = fl; sn[ns++] = fh - fl; } }   // 远端影子块按游戏地址另存（far.bin）
    span_t *sp = NULL; int nsp = 0, cap = 0; *nreg = 0;
    int s2a_guest_fd(void); int gfd = s2a_guest_fd(); uint64_t nfile = 0;   // vawin.c：客体内存文件后备的描述符（没开 = -1）
    struct { uint64_t a, n; int prot; } *nr = NULL; int nnr = 0, cnr = 0;   // 临时加了读权限的段（存完原样还原）
    g_dump_noread = 0; g_dump_noread_b = 0;
    // 1) 收集要存的连续页段：当前可读、非代码、不在服务层共享内存里、驻留（含换出）、非全零
    for (vm_address_t a = base; a < base + size; ) {   // vm_region_*_64：iOS SDK 不给 mach_vm.h（同 vawin.c / far.c）
        vm_address_t r = a; vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &r, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS || r >= base + size) break;
        uint64_t lo = r < base ? base : r, hi = r + sz > base + size ? base + size : r + sz; a = r + sz;
        if (s2a_prot_is_code(info.protection, info.max_protection)) continue;
        // 宿主为模拟游戏设的权限（MapMemory 期间的源页、SetMemoryPermission 设成不可访问的页）把页设成不可读，数据仍有用：冻结中临时加读、存完原样还原
        //   （原先跳过这类页，恢复后是全零——一款 Switch 2 游戏切纤程时读到全零的上下文，崩在游戏自带的校验陷阱上）
        int noread = !(info.protection & VM_PROT_READ);
        if (noread && (!(info.max_protection & VM_PROT_READ) || mprotect((void *)lo, hi - lo, PROT_READ))) continue;
        if (noread) { g_dump_noread++; g_dump_noread_b += hi - lo;
            if (nnr == cnr) { cnr = cnr ? cnr * 2 : 64; nr = realloc(nr, sizeof *nr * (size_t)cnr); }
            nr[nnr].a = lo; nr[nnr].n = hi - lo; nr[nnr].prot = info.protection; nnr++; }
        (*nreg)++;
        size_t np = (size_t)((hi - lo) / pg); char *vec = malloc(np); if (!vec || mincore((void *)lo, hi - lo, vec)) { free(vec); continue; }
        // 文件后备窗口（S2A_GUEST_FILE，iPhone 缺省开；runtime/src/vawin.c 窗口映射在后备文件偏移 0）：写过的页被系统写回文件、撤出内存后，mincore 既不报
        //   驻留也不报换出（换出标志只管匿名内存），原先按「没碰过」跳过，恢复后是全零（11-17 iPhone 一款大游戏恢复后 6 秒崩在分配器读空指针，同款 Mac 没开后备、正常）。
        //   后备文件是稀疏的：从没写过 / 游戏还页打过洞的地方是洞。这段在文件里有数据的页，mincore 没报也照样读（读时系统从文件读回）
        if (gfd >= 0) for (off_t o = (off_t)(lo - base), end = (off_t)(hi - base); o < end; ) {
            off_t d = lseek(gfd, o, SEEK_DATA); if (d < 0 || d >= end) break;
            off_t h = lseek(gfd, d, SEEK_HOLE); if (h < 0 || h > end) h = end;
            for (off_t q = d & ~(off_t)(pg - 1); q < h; q += pg) { size_t i = (size_t)((uint64_t)q - (lo - base)) / pg; if (i < np && !(vec[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) { vec[i] |= MINCORE_PAGED_OUT; nfile++; } }
            o = h;
        }
        for (size_t i = 0; i < np; i++) {
            uint64_t pa = lo + i * pg;
            if (!(vec[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) continue;
            if (in_ranges(pa, sb, sn, ns) || page_zero((const uint8_t *)pa)) continue;
            if (nsp && sp[nsp - 1].a + sp[nsp - 1].n == pa && sp[nsp - 1].n < CH) sp[nsp - 1].n += pg;
            else { if (nsp == cap) { cap = cap ? cap * 2 : 4096; sp = realloc(sp, sizeof *sp * (size_t)cap); } sp[nsp++] = (span_t){pa, pg}; }
        }
        free(vec);
    }
    // 2) 并行压缩、按序写出（每批 64 段）
    uint64_t raw = 0, comp = 0; int e = 0;
    for (int b0 = 0; b0 < nsp && !e; b0 += 64) {
        int bn = nsp - b0 < 64 ? nsp - b0 : 64; uint8_t **out = calloc(64, sizeof *out); size_t *ol = calloc(64, sizeof *ol);
        dispatch_apply((size_t)bn, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            span_t s = sp[b0 + (int)k]; out[k] = malloc(s.n + 4096);
            ol[k] = out[k] ? compression_encode_buffer(out[k], s.n, (const uint8_t *)s.a, s.n, NULL, COMPRESSION_LZ4) : 0;
        });
        for (int k = 0; k < bn; k++) {
            span_t s = sp[b0 + k]; uint64_t cl = ol[k] ? ol[k] : s.n;
            e |= fwrite(&s.a, 8, 1, f) != 1 || fwrite(&s.n, 8, 1, f) != 1 || fwrite(&cl, 8, 1, f) != 1;
            e |= fwrite(ol[k] ? out[k] : (const uint8_t *)s.a, 1, cl, f) != cl;
            raw += s.n; comp += cl; free(out[k]);
        }
        free(out); free(ol);
    }
    uint64_t z = 0; e |= fwrite(&z, 8, 1, f) != 1;
    for (int i = 0; i < nnr; i++) mprotect((void *)nr[i].a, nr[i].n, (nr[i].prot & VM_PROT_WRITE ? PROT_WRITE : 0) | (nr[i].prot & VM_PROT_EXECUTE ? PROT_EXEC : 0));   // 还原（原先没有读）
    if (gfd >= 0) LOG("即时存档：客体内存文件后备 已写回文件、不在内存里的页 %llu 个按文件数据区补存（%.1f MB）", (unsigned long long)nfile, nfile * (double)pg / 1048576.0);
    if (nnr) LOG("即时存档：不可读的内存段 %d 段 %.1f MB 临时加读存进快照（游戏设的权限，恢复时照权限账收回）", nnr, g_dump_noread_b / 1048576.0);
    free(nr); free(sp); *raw_out = raw; *comp_out = comp; return e ? -1 : 0;
}

// ---------- 存 ----------
static FILE *open_in(const char *dir, const char *name, const char *mode) { char p[2048]; snprintf(p, sizeof p, "%s/%s", dir, name); return fopen(p, mode); }
static int close_sync(FILE *f) { int e = fflush(f) || fsync(fileno(f)); return fclose(f) || e ? -1 : 0; }
#include <fts.h>
static void rmtree(const char *path) {   // 删整棵目录（快照的临时 / 旧目录）；不存在不算错
    char *av[] = {(char *)path, NULL}; FTS *fs = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL); if (!fs) return;
    for (FTSENT *e; (e = fts_read(fs));) { if (e->fts_info == FTS_DP) rmdir(e->fts_path); else if (e->fts_info == FTS_F || e->fts_info == FTS_SL || e->fts_info == FTS_SLNONE || e->fts_info == FTS_DEFAULT) unlink(e->fts_path); }
    fts_close(fs);
}
// 新快照先写进 <目录>.new，全部写完、清单标「完整」后才原子换上；中途失败旧快照原样留着（存一次失败不能把玩家上一份好快照弄坏）
typedef snap_fp_cb fp_cb;
static void fps_all(fp_cb cb); static FILE *g_fp_f, *g_lay_f; static void fp_write(const char *name, snap_fp fp);
static int g_lay_n, g_lay_fields, g_lay_bad; static char g_lay_badnames[1024];
const char *s2a_snap_path(const char *v);
static void (*g_snap_done_cb)(int ok, const char *dir);
static _Atomic int g_snap_busy;
void s2a_snap_thaw(void);   // thread.c
static void snap_finish(int ok, const char *dir, int exit_after) {
    if (exit_after) { LOG("即时存档：存完退出进程（快照%s）", ok ? "完整" : "不完整，恢复时会拒绝"); s2a_logcon_flush(); _exit(ok ? 0 : 5); }
    s2a_snap_thaw(); atomic_store(&g_snap_busy, 0);
    LOG("即时存档：%s，游戏接着跑", ok ? "存好了" : "这次没存成");
    if (g_snap_done_cb) g_snap_done_cb(ok, dir);
}
static void snap_take_(const char *final_dir, int exit_after);
static void snap_take(const char *final_dir) { const char *x = getenv("S2A_SNAP_EXIT"); snap_take_(final_dir, x && *x == '1'); }   // 测试定时器：缺省同产品（存完接着玩），S2A_SNAP_EXIT=1 存完退出
static void snap_take_(const char *final_dir, int exit_after) {
    double t0 = now_s();
    static char tmpd[2048]; snprintf(tmpd, sizeof tmpd, "%s.new", final_dir); rmtree(tmpd);
    const char *dir = tmpd;
    if (mkdir(dir, 0755)) { LOG("【红】即时存档：建不了快照临时目录 %s（errno %d），不存", dir, errno); snap_finish(0, final_dir, 0); return; }
    snap_id id; current_id(&id);   // 冻结前算存档目录哈希（冻结后游戏不再写）
    { char g[2048]; snprintf(g, sizeof g, "%s/a_last.png", dir); if (nvn_snap_grab) nvn_snap_grab(g); }   // 验证用：存档时刻的画面
    double t1 = now_s();
    int nthr = 0, nst[8], us = -1;
    for (int k = 0; k < 5 && us < 0; k++) { us = s2a_snap_freeze(2000, &nthr, nst); if (us < 0) LOG("【黄】即时存档：第 %d 次冻结 2 秒没到齐，重试", k + 1); }
    if (us < 0) { rmtree(dir); LOG("【红】即时存档：5 次冻结都没到齐，放弃这次存档（游戏照常跑；临时目录已删，旧快照如有原样保留）"); snap_finish(0, final_dir, 0); return; }
    if (nvn_be_drain) nvn_be_drain();   // 已提交的命令做完、出图队列清空（GPU 不再写游戏内存）
    uint64_t gns = guest_ns();   // 游戏时间（冻结那一刻）：恢复后从这里接着走（同 Switch 挂起 / 唤醒，#495）
    double t2 = now_s();
    // 冻结后再算一次存档目录哈希：两次不一致 = 冻结前一刻游戏在写存档，这份快照不可信（拒绝写出）
    char save2[80]; int n2; save_dir_hash(save2, &n2);
    if (strcmp(save2, id.save)) { LOG("【黄】即时存档：冻结前后存档目录哈希不同（游戏正在写存档），这次不存；游戏照常跑，旧快照（如有）原样保留"); rmtree(dir); snap_finish(0, final_dir, exit_after); return; }
    int e = 0; uint64_t raw = 0, comp = 0; int nreg = 0;
    char sfull[80]; int sfn = 0; save_full_hash(sfull, &sfn);
    { char root[2048], dst[2048]; save_root(root, sizeof root); snprintf(dst, sizeof dst, "%s/save_tree", dir);
      if (clonefile(root, dst, 0)) { LOG("【红】即时存档：克隆存档树失败（errno %d）", errno); e = 1; } }
    FILE *f = open_in(dir, "svcmem.bin", "wb"); e |= !f || s2a_snap_svcmem_save(f) || close_sync(f);
    f = open_in(dir, "kernel.bin", "wb"); e |= !f || s2a_snap_kernel_save(f) || close_sync(f);
    { int s2a_snap_nro_save(FILE *); f = open_in(dir, "nro.bin", "wb"); e |= !f || s2a_snap_nro_save(f) || close_sync(f); }
    { int s2a_snap_far_save(FILE *); f = open_in(dir, "far.bin", "wb"); e |= !f || s2a_snap_far_save(f) || close_sync(f); }
    f = open_in(dir, "hlog.bin", "wb"); e |= !f || s2a_snap_hlog_save(f) || close_sync(f);
    f = open_in(dir, "hslot.bin", "wb"); e |= !f || s2a_snap_hostslots_save(f) || close_sync(f);
    f = open_in(dir, "handout.bin", "wb"); e |= !f || handout_save(f) || close_sync(f);
    f = open_in(dir, "blob.bin", "wb"); e |= !f || blob_save(f) || close_sync(f);
    e |= !nvn_snap_save || nvn_snap_save(dir) != 0;   // 直连图形层实时状态
    { char p[2048]; snprintf(p, sizeof p, "%s/ipc.bin", dir); if (!S2A_SnapLogSave) { LOG("【红】即时存档：宿主没链服务层，无请求日志"); e = 1; } else e |= S2A_SnapLogSave(p) != 0; }
    { char p[2048]; snprintf(p, sizeof p, "%s/audio.bin", dir); e |= !S2A_SnapAudioSave || S2A_SnapAudioSave(p) != 0; }
    double t3 = now_s();
    f = open_in(dir, "mem.bin", "wb"); e |= !f || dump_mem(f, &raw, &comp, &nreg) || close_sync(f);
    double t4 = now_s();
    { int s2a_snap_cs_moved(void); int mv = s2a_snap_cs_moved();   // 在服务请求里阻塞、按入口记、进了请求日志的线程：存档途中它的请求完成了，可能已建句柄、改了正在写的内核账——这次不算（不进日志的照存，见 thread.c）
      if (mv) { LOG("【黄】即时存档：%d 条进了请求日志的阻塞请求在存档途中等到了回复，这次不存（游戏照常跑；换个时机再存）", mv); e = 1; } }
    f = open_in(dir, "manifest.tsv", "w");
    if (f) {
        fprintf(f, "版本\t1\n构建号\t%s\n宿主二进制\t%s\n程序号\t%s\n窗口\t%s\n布局\t%s\n存档目录\t%s\n存档文件数\t%d\n", id.build, id.exe, id.prog, id.win, id.layout, id.save, id.save_n);
        fprintf(f, "存档全量\t%s\n存档全量文件数\t%d\n", sfull, sfn);
        fprintf(f, "游戏时间_ns\t%llu\n", (unsigned long long)gns);
        { char d[2048] = "", pv[2048] = ""; if (S2A_SnapDataRoot && S2A_SnapDataRoot(d, sizeof d) > 0) root_portable(d, pv, sizeof pv); fprintf(f, "数据根\t%s\n", pv); }
        g_fp_f = f; g_lay_f = open_in(dir, "layouts.bin", "wb"); g_lay_n = g_lay_fields = g_lay_bad = 0; g_lay_badnames[0] = 0;
        fps_all(fp_write);
        if (!g_lay_f || close_sync(g_lay_f)) { LOG("【黄】即时存档：宿主结构完整布局（layouts.bin）没写成；这个快照将来换版本时只能按指纹比、不能按字段转"); }
        else LOG("即时存档：宿主结构完整布局 %d 个（字段 %d 个）记进 layouts.bin%s%s", g_lay_n, g_lay_fields, g_lay_bad ? "；布局不明（换版本只能拒绝）：" : "", g_lay_badnames);
        g_lay_f = NULL;
        {   // 模块落点（游戏看得见的地址）：恢复时逐个比（名字、基址、映像长度），任何一项不等 = 布局变了（C 档），接不上
            extern module_t *g_mod; extern int g_nmod; fprintf(f, "模块数\t%d\n", g_nmod);
            for (int i = 0; i < g_nmod; i++) fprintf(f, "模块%d\t%s\t%llu\t%llu\n", i, g_mod[i].name, (unsigned long long)(uintptr_t)g_mod[i].base, (unsigned long long)g_mod[i].size); }
        { void s2a_snap_arena_get(uint64_t *, uint64_t *, uint64_t *); uint64_t s2a_snap_arena_len(void); uint64_t cb = 0, cu = 0, vu = 0; s2a_snap_arena_get(&cb, &cu, &vu);
          fprintf(f, "命令记录区\t%llu\t%llu\n", (unsigned long long)cb, (unsigned long long)s2a_snap_arena_len()); }
        fprintf(f, "线程\t%d\n停法\t入口 %d 出口 %d 等待 %d 睡眠 %d 已退出 %d 未启动 %d\n冻结到齐_us\t%d\n", nthr, nst[1], nst[2], nst[3], nst[4], nst[5], nst[6], us);
        fprintf(f, "内存段\t%d\n内存原始_MB\t%.1f\n内存压缩后_MB\t%.1f\n", nreg, raw / 1048576.0, comp / 1048576.0);
        fprintf(f, "耗时_哈希_s\t%.3f\n耗时_冻结_s\t%.3f\n耗时_内存账内核账_s\t%.3f\n耗时_内存_s\t%.3f\n完整\t%d\n", t1 - t0, t2 - t1, t3 - t2, t4 - t3, !e);
        e |= close_sync(f);
    } else e = 1;
    LOG("%s即时存档：写到 %s；冻结 %d us（线程 %d：入口 %d 出口 %d 等待 %d 睡眠 %d 已退出 %d 未启动 %d）；内存 %.0f MB → %.0f MB；哈希 %.2f s、冻结 %.2f s、账 %.2f s、内存 %.2f s；存档目录 %d 个文件 %.12s…",
        e ? "【红】" : "", dir, us, nthr, nst[1], nst[2], nst[3], nst[4], nst[5], nst[6], raw / 1048576.0, comp / 1048576.0, t1 - t0, t2 - t1, t3 - t2, t4 - t3, id.save_n, id.save);
    if (!e) {   // 换上：旧的挪开 → 新的改名到位 → 删旧的（改名在同一目录下，原子）
        char old[2100]; snprintf(old, sizeof old, "%s.old", final_dir); rmtree(old);
        if (rename(final_dir, old) && errno != ENOENT) { LOG("【红】即时存档：旧快照挪不开（errno %d），新快照留在 %s", errno, dir); e = 1; }
        else if (rename(dir, final_dir)) { LOG("【红】即时存档：新快照换不上（errno %d），旧快照放回", errno); rename(old, final_dir); e = 1; }
        else { rmtree(old); LOG("即时存档：新快照已换上 %s", final_dir); }
    } else { rmtree(dir); LOG("【红】即时存档：这次没存成，临时目录已删，旧快照（如有）原样保留"); }
    snap_finish(!e, final_dir, exit_after);
}
// 给界面的入口（游戏里菜单「存下这一刻」）：后台存，存完解冻接着玩、调完成回调（ok、快照目录）。只在起局时开了存档模式（S2A_SNAP_MODE=1，请求日志从开局记起）时可用；
//   正在存回 -2；没开回 -1。快照目录由调用方给（0.6.0 落点见 s2a_snap_dir_for），每款只留一份：新的存好后原子换掉旧的
void s2a_snap_on_done(void (*cb)(int ok, const char *dir)) { g_snap_done_cb = cb; }
// 这一款的快照目录（0.6.0 定的落点，每款一份，删这款时随这款的文件夹一起删）。父目录不存在就建；回 0 成功
//   iPhone：这款的文档根（<容器>/Documents/games/<游戏号>，host.log、金手指、wire 同在的那个文件夹，「文件」App 里看得到）下的 snapshot/。
//     游戏里（gid 为空）取本局文档根 s2a_docs_root；游戏库卡片上（还没起局）给 gid，按容器文档根 s2a_container_docs 拼 games/<gid>
//   Mac 启动器：起局带 S2A_SNAPSHOT_DIR = 游戏库里这款文件夹下的 snapshot/（pack/jobs/build.py），游戏里调就用它
//   其余（没经启动器起的 Mac 局、单测）：<文档根>/snapshot
int s2a_snap_dir_for(const char *gid, char *out, size_t n) {
    if (!out || !n) return -1;
    const char *e = getenv("S2A_SNAPSHOT_DIR");
    char base[2048];
    if ((!gid || !*gid) && e && *e) snprintf(base, sizeof base, "%s", e);
    else {
        char docs[2048];
        if (gid && *gid) {   // 游戏库卡片（只在 iPhone 上有）
#if defined(__APPLE__) && TARGET_OS_IPHONE
            char cd[1800]; if (strchr(gid, '/') || s2a_container_docs(cd, sizeof cd) >= (int)sizeof cd) return -1;
            snprintf(docs, sizeof docs, "%s/games/%s", cd, gid);
#else
            return -1;
#endif
        } else if (s2a_docs_root(docs, sizeof docs) >= (int)sizeof docs) return -1;
        if (snprintf(base, sizeof base, "%s/snapshot", docs) >= (int)sizeof base) return -1;
    }
    for (char *q = base + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(base, 0755); *q = '/'; }   // 建父目录（快照目录本身由存档时原子换上）
    if (snprintf(out, n, "%s", base) >= (int)n) return -1;
    return 0;
}
static int man_get(const char *dir, const char *key, char *out, size_t n);
static void save_dir_hash(char *out, int *nfiles);
// 存快照之后游戏又存过档没有（界面在「回到那一刻」之前问玩家用；只读，不改任何东西）：1 变过、0 没变、-1 判不了
int s2a_snap_save_changed(const char *dir) {
    char want[256], cur[80]; int n; if (man_get(dir, "存档目录", want, sizeof want)) return -1;
    // 游戏库里（这一款还没起局、服务层没起）：存档在哪按快照清单记的数据根算（同恢复前核对的做法）
    if (!g_root_hint[0] && !man_get(dir, "数据根", g_root_hint_v, sizeof g_root_hint_v) && g_root_hint_v[0]) root_expand(g_root_hint_v, g_root_hint, sizeof g_root_hint);
    save_dir_hash(cur, &n); return strcmp(want, cur) != 0; }
// 这一款有没有能用的快照：清单在、且「完整 1」
int s2a_snap_exists(const char *dir) { char v[16]; return dir && *dir && !man_get(dir, "完整", v, sizeof v) && !strcmp(v, "1"); }
static void *snap_req_main(void *a) { snap_take_((const char *)a, 0); free(a); return NULL; }
int s2a_snap_request_save(const char *dir) {
    if (!s2a_snap_logging() || !dir || !*dir) return -1;
    int z = 0; if (!atomic_compare_exchange_strong(&g_snap_busy, &z, 1)) return -2;
    char *d = strdup(s2a_snap_path(dir)); pthread_t th;
    if (!d || pthread_create(&th, NULL, snap_req_main, d)) { free(d); atomic_store(&g_snap_busy, 0); return -1; }
    pthread_detach(th); return 0;
}
// 快照目录：绝对路径照用；相对路径落在文档根下（iPhone 上即 App 的 Documents，Mac 上 S2A_DOCS），同一套起局环境两端都能用
const char *s2a_snap_path(const char *v) {
    static char buf[2][2048]; static int k; char *o = buf[k++ & 1];
    if (!v || !*v || v[0] == '/') return v;
    s2a_docs_path(o, sizeof buf[0], "%s", v); return o;
}
static void *snap_timer(void *arg) {
    (void)arg; long sec = atol(getenv("S2A_SNAP_AT")); const char *dir = s2a_snap_path(getenv("S2A_SNAP_DIR"));
    int s2a_thread_alive_count(void);
    while (s2a_thread_alive_count() == 0) usleep(200000);   // 从游戏线程起来算（进程可能先排很久显卡局槽）
    sleep((unsigned)sec);
    LOG("即时存档：游戏起来后 %ld 秒到点，开始存档 → %s", sec, dir);
    { int z = 0; if (!atomic_compare_exchange_strong(&g_snap_busy, &z, 1)) { LOG("【黄】即时存档：定时到点时正在存，跳过"); return NULL; } }
    snap_take(dir);
    return NULL;
}
// 测试开关（S2A_SNAP_RESTART_AT=<秒>、S2A_SNAP_RESTART_DIR=<快照目录>）：游戏起来后到点设好恢复目录、请求进程内重启——同界面「回到上次存下的这一刻」走的路
#include "s2a_session.h"
static void snap_restart_cb(int rc, const char *why, void *ctx) { (void)ctx; LOG("即时存档：进程内重启%s%s%s", rc ? "没成：" : "已开始", rc && why ? why : "", ""); }
static void *snap_restart_timer(void *arg) {
    (void)arg; long sec = atol(getenv("S2A_SNAP_RESTART_AT")); const char *dir = s2a_snap_path(getenv("S2A_SNAP_RESTART_DIR"));
    int s2a_thread_alive_count(void); while (s2a_thread_alive_count() == 0) usleep(200000);
    sleep((unsigned)sec);
    while (atomic_load(&g_snap_busy)) usleep(100000);   // 正在存就等存完
    LOG("即时存档：游戏起来后 %ld 秒到点，回到快照（进程内重启）%s", sec, dir);
    setenv("S2A_SNAP_RESTORE", dir, 1);
    int rc = s2a_host_restart(snap_restart_cb, NULL); if (rc) LOG("【红】即时存档：进程内重启请求被拒 %d", rc);
    return NULL;
}
__attribute__((constructor)) static void snap_restart_ctor(void) {
    const char *at = getenv("S2A_SNAP_RESTART_AT"), *dir = getenv("S2A_SNAP_RESTART_DIR");
    if (!at || !*at || !dir || !*dir) return;
    pthread_t th; pthread_create(&th, NULL, snap_restart_timer, NULL); pthread_detach(th);
}
__attribute__((constructor)) static void snap_ctor(void) {
    const char *at = getenv("S2A_SNAP_AT"), *dir = getenv("S2A_SNAP_DIR");
    if (!at || !*at || !s2a_snap_saving()) return;
    if (!dir || !*dir) { fprintf(stderr, "【红】即时存档：设了 S2A_SNAP_AT 没设 S2A_SNAP_DIR，不存\n"); return; }
    pthread_t th; pthread_create(&th, NULL, snap_timer, NULL); pthread_detach(th);
}

// ---------- 恢复前校验 ----------
static int man_get(const char *dir, const char *key, char *out, size_t n) {
    FILE *f = open_in(dir, "manifest.tsv", "r"); if (!f) return -1;
    char line[1024]; size_t kl = strlen(key); int ok = -1;
    while (fgets(line, sizeof line, f)) if (!strncmp(line, key, kl) && line[kl] == '\t') { snprintf(out, n, "%s", line + kl + 1); out[strcspn(out, "\n")] = 0; ok = 0; break; }
    fclose(f); return ok;
}
// 回 0 = 全部一致可以恢复；否则打红、说清哪一项不符，调用方立刻退出（此刻还没起服务层、没碰存档目录）
// 恢复不成时给玩家的说法（0.6.0 做界面入口时读这个文件；不靠日志）：文档根下 snap_result.tsv，「结果 / 分类 / 给玩家的话」三行
static int g_snap_old, g_snap_save_moved;
void s2a_snap_mark_old(void) { g_snap_old = 1; }
void s2a_snap_result_note(int ok) {
    char p[2048]; s2a_docs_path(p, sizeof p, "snap_result.tsv"); FILE *f = fopen(p, "w"); if (!f) return;
    if (ok) fprintf(f, "结果\t恢复成功\n");
    else if (g_snap_save_moved) fprintf(f, "结果\t需要确认\n分类\t存档已变\n给玩家\t存这个快照之后，游戏又存过档；恢复会把游戏存档退回到快照那一刻（现在的存档会先备份）。确认后再恢复\n");
    else if (g_snap_old) { fprintf(f, "结果\t拒绝\n分类\t旧版快照\n给玩家\t这个快照是旧版 S2Arm 存的，新版接不上，已删掉；游戏自己的存档不受影响\n");
        const char *d = s2a_snap_path(getenv("S2A_SNAP_RESTORE")); if (d && *d) { rmtree(d); LOG("即时存档恢复：旧版快照接不上，已删掉 %s", d); } }
    else fprintf(f, "结果\t失败\n分类\t快照不完整或损坏\n给玩家\t这个快照读不了（可能存的时候没存完）；游戏自己的存档不受影响\n");
    fclose(f);
}
static int man_get(const char *dir, const char *key, char *out, size_t n);
// 按整块存的宿主结构（游戏内存里的 NVN 对象、图形回放状态、视频表等）的布局指纹：存档时全部记进清单，恢复前逐个比，不同即拒绝（C 档）
void hle_snap_fps(fp_cb) __attribute__((weak_import)); void nvn_snap_fps(fp_cb) __attribute__((weak_import)); void nvn2_codec_snap_fps(fp_cb) __attribute__((weak_import)); void nvn2_snap_fps(fp_cb) __attribute__((weak_import));
uint64_t S2A_SnapAudioFp(void) __attribute__((weak_import));   // SnapLog.cs：音频渲染器工作缓冲的布局指纹
static void fps_all(fp_cb cb) { if (S2A_SnapAudioFp) cb("audio.renderer", (snap_fp){S2A_SnapAudioFp(), NULL, 0}); if (hle_snap_fps) hle_snap_fps(cb); if (nvn_snap_fps) nvn_snap_fps(cb); if (nvn2_codec_snap_fps) nvn2_codec_snap_fps(cb); if (nvn2_snap_fps) nvn2_snap_fps(cb); }
// 存：指纹进清单；完整布局进 layouts.bin（换版本时按字段转用，见 snapfmt.h）。托管侧（音频）没有 C 布局，记「不明」
static void fp_write(const char *name, snap_fp fp) {
    fprintf(g_fp_f, "布局指纹\t%s\t%016llx\n", name, (unsigned long long)fp.fp);
    if (!g_lay_f) return;
    if (snap_lay_write(g_lay_f, name, fp.lay)) { fclose(g_lay_f); g_lay_f = NULL; return; }
    g_lay_n++; if (fp.lay && !fp.lay->bad) g_lay_fields += (int)fp.lay->n;
    else { g_lay_bad++; size_t k = strlen(g_lay_badnames); snprintf(g_lay_badnames + k, sizeof g_lay_badnames - k, "%s%s（%s）", k ? "、" : "", name, fp.lay ? fp.lay->why : "没有 C 布局"); }
}
// 恢复：读快照的 layouts.bin（第一次用时整份读进来）
typedef struct { char name[96]; snap_lay lay; } lay_ent; static lay_ent *g_old_lay; static int g_old_lay_n, g_old_lay_loaded;
static const snap_lay *old_lay(const char *dir, const char *name) {
    if (!g_old_lay_loaded) { g_old_lay_loaded = 1; FILE *f = open_in(dir, "layouts.bin", "rb");
        if (f) { lay_ent e; int r, cap = 0; while ((r = snap_lay_read(f, e.name, sizeof e.name, &e.lay)) == 1) {
                if (g_old_lay_n == cap) { cap = cap ? cap * 2 : 64; lay_ent *n = realloc(g_old_lay, sizeof *n * (size_t)cap); if (!n) { snap_lay_free(&e.lay); break; } g_old_lay = n; }
                g_old_lay[g_old_lay_n++] = e; }
            if (r < 0) { snap_lay_free(&e.lay); LOG("【黄】即时存档恢复：layouts.bin 读到第 %d 条坏了，后面的结构不能按字段转", g_old_lay_n); }
            fclose(f); } }
    for (int i = 0; i < g_old_lay_n; i++) if (!strcmp(g_old_lay[i].name, name)) return &g_old_lay[i].lay;
    return NULL;
}
static const char *g_fp_dir; static int g_fp_bad, g_fp_n, g_fp_conv;
// 布局转换表：快照里的布局与本版不同、能按字段转的结构。恢复处经 s2a_snap_conv_fread 读整块结构时按它转；
//   带 magic 的（住在游戏内存里的对象）在页内容写回后整片找一遍、原地转（conv_guest_objs）
static snap_conv g_conv[128]; static int g_nconv;
static snap_conv *conv_find(const char *name) { for (int i = 0; i < g_nconv; i++) if (!strcmp(g_conv[i].name, name)) return &g_conv[i]; return NULL; }
size_t s2a_snap_conv_fread(void *dst, size_t size, size_t n, FILE *f, const char *name) {
    snap_conv *e = conv_find(name);
    if (!e || e->c->size != size) return fread(dst, size, n, f);   // 布局相同（或调用方读的不是登记的那个结构）：原样读
    uint8_t *tmp = malloc(e->o->size ? e->o->size : 1); size_t k = 0;
    for (; k < n && tmp; k++) { if (fread(tmp, e->o->size, 1, f) != 1) break; snap_conv_one(e, tmp, (uint8_t *)dst + k * size); }
    free(tmp); return k;
}
static void conv_guest_objs(const uint64_t *rg, int nrg) {   // rg：{起点, 长度} × nrg，按地址排好、相邻的已并成一段（跨记录的对象也在一段里）
    snap_conv *ev[128]; int ne = 0; double t0 = now_s(); uint64_t scanned = 0; uint32_t omax = 0;
    for (int i = 0; i < g_nconv; i++) if (g_conv[i].magic) { const char *why = snap_conv_scannable(&g_conv[i]);
        if (why) { LOG("【黄】即时存档恢复：「%s」%s，游戏内存里的这种对象没转", g_conv[i].name, why); continue; }
        ev[ne++] = &g_conv[i]; if (g_conv[i].o->size > omax) omax = g_conv[i].o->size; }
    if (!ne) return;
    uint8_t *tmp = malloc(omax);
    for (int r = 0; r < nrg && tmp; r++) { snap_conv_scan(ev, ne, (uint8_t *)(uintptr_t)rg[2 * r], rg[2 * r + 1], tmp); scanned += rg[2 * r + 1]; }
    free(tmp);
    for (int j = 0; j < ne; j++) LOG("%s即时存档恢复：游戏内存里的「%s」按新布局原地转 %llu 个（旧 %u 字节 → 新 %u 字节；整数放不下 %llu 处、丢掉的旧字段有值 %llu 处）",
        ev[j]->nlossy || ev[j]->ndrop ? "【黄】" : "", ev[j]->name, (unsigned long long)ev[j]->nobj, ev[j]->o->size, ev[j]->c->size, (unsigned long long)ev[j]->nlossy, (unsigned long long)ev[j]->ndrop);
    LOG("即时存档恢复：按 magic 找对象扫了 %.0f MB，%.2f 秒", scanned / 1048576.0, now_s() - t0);
}
// 布局指纹核对：相同直接用；不同按两版完整布局给逐字段转换计划，能转的登记进转换表；接不上的（布局不明 / 字段类型变了）黄字点名、照常继续——
//   校验不过不拒绝：那个结构恢复出来可能不对，真出错时由出错处报
static void fp_check(const char *name, snap_fp sfp) {
    uint64_t fp = sfp.fp;
    FILE *f = open_in(g_fp_dir, "manifest.tsv", "r"); if (!f) { g_fp_bad++; return; }
    char line[512], want[160]; snprintf(want, sizeof want, "布局指纹\t%s\t", name); size_t wl = strlen(want); int found = 0;
    while (fgets(line, sizeof line, f)) if (!strncmp(line, want, wl)) { found = 1; uint64_t v = strtoull(line + wl, NULL, 16); g_fp_n++;
        if (v != fp) {
            const snap_lay *o = old_lay(g_fp_dir, name); uint32_t st[4]; char why[256] = "";
            if (!o) snprintf(why, sizeof why, "快照里没有完整布局（旧版快照）");
            int ok = o && !snap_lay_plan(o, sfp.lay, st, why, sizeof why);
            if (ok && g_nconv < (int)(sizeof g_conv / sizeof g_conv[0])) {
                snap_conv *e = &g_conv[g_nconv++]; memset(e, 0, sizeof *e); snprintf(e->name, sizeof e->name, "%s", name); e->o = o; e->c = sfp.lay; e->magic = sfp.magic; g_fp_conv++;
                LOG("即时存档恢复：宿主结构「%s」布局与快照时不同（快照 %016llx，本版 %016llx），按字段转（原样 %u、换宽 / 精度 %u、新加取缺省 %u、丢掉 %u）%s",
                    name, (unsigned long long)v, (unsigned long long)fp, st[0], st[1], st[2], st[3], sfp.magic ? "；游戏内存里的这种对象写回后原地转" : ""); }
            else { LOG("【黄】即时存档恢复：宿主结构「%s」布局与快照时不同（快照 %016llx，本版 %016llx），不能按字段转：%s；照原样继续", name, (unsigned long long)v, (unsigned long long)fp, ok ? "转换表满了" : why);
                g_fp_bad++; } } break; }
    fclose(f);
    if (!found) LOG("即时存档恢复：宿主结构「%s」是本版新加的，快照里没有（按缺省）", name);
}
// 恢复局早期（vawin.c 占命令记录区时，服务层与清单校验之前）读清单里的两个数：值格式「a\tb」（十进制）
int s2a_snap_manifest_u64(const char *key, uint64_t *a, uint64_t *b) {
    const char *dir = s2a_snap_path(getenv("S2A_SNAP_RESTORE")); char v[256], *e;
    if (!dir || !*dir || man_get(dir, key, v, sizeof v)) return -1;
    *a = strtoull(v, &e, 10); *b = e && *e == '\t' ? strtoull(e + 1, NULL, 10) : 0; return 0;
}
// 恢复局的窗口按快照原样占（vawin.c 构造期调）：清单「窗口」= 基址+长度（十六进制）。没有 / 读不出回 -1
int s2a_snap_manifest_win(uint64_t *base, uint64_t *size) {
    const char *dir = s2a_snap_path(getenv("S2A_SNAP_RESTORE")); char v[256], *e;
    if (!dir || !*dir || man_get(dir, "窗口", v, sizeof v)) return -1;
    *base = strtoull(v, &e, 16); if (!e || *e != '+') return -1; *size = strtoull(e + 1, NULL, 16); return *base && *size ? 0 : -1;
}
int s2a_snap_restore_check(const char *dir) {
    if (!man_get(dir, "数据根", g_root_hint_v, sizeof g_root_hint_v) && g_root_hint_v[0]) root_expand(g_root_hint_v, g_root_hint, sizeof g_root_hint);
    snap_id id; current_id(&id);
    struct { const char *key, *cur; } it[] = { {"构建号", id.build}, {"宿主二进制", id.exe}, {"程序号", id.prog}, {"窗口", id.win}, {"布局", id.layout}, {"存档目录", id.save} };
    char v[256]; int bad = 0;
    if (man_get(dir, "完整", v, sizeof v) || strcmp(v, "1")) { LOG("【红】即时存档恢复：%s 没有完整清单（存档中途失败或不是快照目录），拒绝恢复", dir); return -1; }
    for (size_t i = 0; i < sizeof it / sizeof it[0]; i++) {
        if (man_get(dir, it[i].key, v, sizeof v)) { LOG("【红】即时存档恢复：清单缺「%s」，拒绝恢复", it[i].key); bad++; continue; }
        if (strcmp(v, it[i].cur)) {
            // 宿主二进制不同（App 升级）不再整体拒绝：依赖本版二进制的每一项都已各有判据（布局指纹、模块落点、内存布局逐字段、交出指针身份、门身份），
            //   哪一项接不上由那一项点名拒绝。这里只记一行
            if (i == 1) { LOG("即时存档恢复：宿主二进制与快照时不同（快照 %.12s…，当前 %.12s…），按跨版本恢复", v, it[i].cur); continue; }
            // 存档目录变了 = 存快照之后游戏又存过档。恢复会把存档树写回快照那一刻，后来的进度会退回去：风险认得出，让玩家确认后继续（不堵门）——
            //   界面问过玩家后带 S2A_SNAP_SAVE_ROLLBACK=1 再起；继续前把当前存档整棵备份到文档根 snap_save_backup/<时刻>
            if (i == 5) { const char *ok = getenv("S2A_SNAP_SAVE_ROLLBACK");
                if (!(ok && *ok == '1')) { LOG("【红】即时存档恢复：存这个快照之后游戏又存过档（快照 %.12s…，当前 %.12s…）；恢复会把存档退回快照那一刻，等玩家确认（S2A_SNAP_SAVE_ROLLBACK=1）", v, it[i].cur); g_snap_save_moved = 1; bad++; continue; }
                char root[2048], bk[2048], nm[64]; save_root(root, sizeof root); snprintf(nm, sizeof nm, "snap_save_backup/%lld", (long long)time(NULL)); s2a_docs_path(bk, sizeof bk, "%s", nm);
                { char par[2048]; s2a_docs_path(par, sizeof par, "%s", "snap_save_backup"); mkdir(par, 0755); }
                if (clonefile(root, bk, 0)) { LOG("【红】即时存档恢复：玩家确认退回存档，但备份当前存档失败（errno %d，%s），不恢复", errno, bk); bad++; continue; }
                LOG("即时存档恢复：存快照之后存档变过，玩家已确认退回；当前存档已备份到 %s", bk); continue; }
            LOG("【红】即时存档恢复：%s不符（快照 %s，当前 %s），拒绝恢复", it[i].key, v, it[i].cur); bad++; }
    }
    if (!bad) {   // 游戏时间接着快照那一刻走（同 Switch 挂起 / 唤醒，#495）：在服务层起来之前就接上，之后谁也看不到时间倒退；恢复期间照常往前走几秒
        char t[64]; uint64_t gns = 0; if (!man_get(dir, "游戏时间_ns", t, sizeof t)) gns = strtoull(t, NULL, 10);
        if (getenv("S2A_SNAP_NOCLOCK")) { LOG("即时存档恢复：对照局，游戏时间不接（S2A_SNAP_NOCLOCK）"); gns = 0; }
        else if (!gns) LOG("【黄】即时存档恢复：快照没记游戏时间，时钟不接");
        if (gns) { uint64_t before = guest_ns(); s2a_guest_clock_set(gns); LOG("即时存档恢复：游戏时间接到快照时刻 %.3f s（不接是 %.3f s）", gns / 1e9, before / 1e9); }
    }
    if (!bad) { g_fp_dir = dir; g_fp_bad = 0; g_fp_n = 0; fps_all(fp_check);
        if (g_fp_bad) LOG("【黄】即时存档恢复：这个快照是旧版存的，%d 个宿主结构布局接不上（见上），照常继续恢复", g_fp_bad);
        if (g_fp_conv) LOG("即时存档恢复：宿主结构布局指纹 %d 个，%d 个按字段转", g_fp_n, g_fp_conv);
        else if (!g_fp_bad) LOG("即时存档恢复：宿主结构布局指纹 %d 个全部一致", g_fp_n); }
    if (!bad) LOG("即时存档恢复：清单六项全部一致（构建号 %s、程序号 %s、窗口 %s、存档目录 %d 个文件）", id.build, id.prog, id.win, id.save_n);
    return bad ? -1 : 0;
}

// ---------- 恢复本体 ----------
// 暂存区（服务请求重放的消息 / 缓冲）：别名区最顶端临时登记一段（svc_mem.c s2a_snap_scratch_map），与游戏内存分开，用完撤掉
uint64_t s2a_snap_scratch_map(uint64_t n); void s2a_snap_scratch_unmap(uint64_t a, uint64_t n);
static uint64_t scratch_pick(uint64_t n) { return s2a_snap_scratch_map(n); }
static void scratch_done(uint64_t a, uint64_t n) { s2a_snap_scratch_unmap(a, n); }
static int load_mem(const char *dir, uint64_t *raw_out) {
    double t_lm0 = now_s(); char p[2048]; snprintf(p, sizeof p, "%s/mem.bin", dir); int fd = open(p, O_RDONLY); if (fd < 0) return -1;
    struct stat st; fstat(fd, &st); uint8_t *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (m == MAP_FAILED) return -1;
    typedef struct { uint64_t a, n, cl; const uint8_t *d; } rec_t; rec_t *rv = NULL; int nr = 0, cap = 0; uint64_t off = 0, raw = 0;
    while (off + 8 <= (uint64_t)st.st_size) {
        uint64_t a = *(uint64_t *)(m + off); if (!a) break;
        uint64_t n = *(uint64_t *)(m + off + 8), cl = *(uint64_t *)(m + off + 16);
        if (nr == cap) { cap = cap ? cap * 2 : 4096; rv = realloc(rv, sizeof *rv * (size_t)cap); }
        rv[nr++] = (rec_t){a, n, cl, m + off + 24}; off += 24 + cl; raw += n;
    }
    // 不可写的页先放开写（模块只读段等；经文件写的记录也照放，之后回填宿主地址槽等仍经映射写），权限账最后收回。顺带认出整段落在文件后备窗口里的记录（vawin.c：窗口整段 MAP_SHARED 映射在后备文件偏移 0）：
    //   这些记录不经映射写，直接 pwrite 进后备文件——经映射写每个 16 KB 页都要走一次文件缺页（11-17 iPhone 大金刚强制文件后备：3115 MB 页内容 1.98 s，
    //   同机大乱斗匿名内存 1040 MB 0.26 s）。页缓存与映射是同一份（统一缓冲区），写进文件后经映射读到的就是新内容
    int gfd = s2a_guest_fd();
    uint8_t *viaf = calloc((size_t)nr + 1, 1); uint64_t *foff = calloc((size_t)nr + 1, 8);
    int fixed = 0, nviaf = 0; uint64_t bviaf = 0;
    // 后备文件的 VM 对象号：另映射它一页取 VM_REGION_TOP_INFO 的 obj_id（同一文件的各处映射是同一个对象；匿名 / 挖回匿名的段是别的对象）。
    //   不能看基本信息里的 shared：那只对别名（vm_remap）置位，普通 MAP_SHARED 文件映射是 0（Mac 实测）
    unsigned fobj = 0;
    if (gfd >= 0) { void *v = mmap(NULL, 0x4000, PROT_READ, MAP_SHARED, gfd, 0);
        if (v != MAP_FAILED) { vm_address_t r = (vm_address_t)v; vm_size_t sz = 0; vm_region_top_info_data_t ti; mach_msg_type_number_t cnt = VM_REGION_TOP_INFO_COUNT; mach_port_t o;
            if (vm_region_64(mach_task_self(), &r, &sz, VM_REGION_TOP_INFO, (vm_region_info_t)&ti, &cnt, &o) == KERN_SUCCESS && r == (vm_address_t)v) fobj = ti.obj_id;
            munmap(v, 0x4000); } }
    for (int i = 0; i < nr; i++) {
        vm_address_t r = rv[i].a; vm_size_t sz = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o;
        if (vm_region_64(mach_task_self(), &r, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &o) != KERN_SUCCESS || r > rv[i].a) { LOG("【红】即时存档恢复：页 %#llx 在 B 里没有映射", (unsigned long long)rv[i].a); munmap(m, (size_t)st.st_size); free(rv); free(viaf); free(foff); return -1; }
        // 经文件写的条件：整条记录在同一段里、这段映射的 VM 对象就是后备文件；文件偏移 = 段偏移 + 段内位移（窗口里 = 地址 − 窗口基址，别名段是源页的偏移）
        if (fobj && r + sz >= rv[i].a + rv[i].n) { vm_address_t r2 = rv[i].a; vm_size_t sz2 = 0; vm_region_top_info_data_t ti; mach_msg_type_number_t c2 = VM_REGION_TOP_INFO_COUNT; mach_port_t o2;
            if (vm_region_64(mach_task_self(), &r2, &sz2, VM_REGION_TOP_INFO, (vm_region_info_t)&ti, &c2, &o2) == KERN_SUCCESS && r2 == r && ti.obj_id == fobj) {
                viaf[i] = 1; foff[i] = bi.offset + (rv[i].a - r); nviaf++; bviaf += rv[i].n; } }
        if (!(bi.protection & VM_PROT_WRITE) || r + sz < rv[i].a + rv[i].n) { if (mprotect((void *)rv[i].a, rv[i].n, PROT_READ | PROT_WRITE)) { LOG("【红】即时存档恢复：页 %#llx 放不开写（errno %d）", (unsigned long long)rv[i].a, errno); munmap(m, (size_t)st.st_size); free(rv); free(viaf); free(foff); return -1; } fixed++; }
    }
    double tp0 = now_s();
    // 游戏把宿主函数地址拷进了自己的数据（分配器函数表等）：按 A→B 宿主地址对照换算。换算表先建好，写回时每段解压完（还在缓存里）当场换算，不再整片内存扫第二遍
    int hobad = 0;   // 交出指针 / 数据段换算失败（与解压失败分开计）
    g_blob_dir = dir;
    uint64_t nm = 0, nunres = 0, nsame = 0, *from = NULL, *to = NULL, *rg = calloc(128, 8), *rgto = calloc(64, 8), *hk = NULL, *hv = NULL; int nr2 = 0; size_t hcap = 1;
    { FILE *hf = open_in(dir, "handout.bin", "rb"); uint32_t mg = 0;
      if (!hf || fread(&mg, 4, 1, hf) != 1 || mg != HO_MAGIC || fread(&nm, 8, 1, hf) != 1) { LOG("【红】即时存档恢复：快照缺交出指针表（或是旧格式）"); hobad++; nm = 0; }
      from = malloc(8 * (nm ? nm : 1)); to = malloc(8 * (nm ? nm : 1)); size_t k2 = 0;
      for (uint64_t i = 0; i < nm; i++) { ho_ent he; if (fread(&he, sizeof he, 1, hf) != 1) { hobad++; break; } he.id[sizeof he.id - 1] = 0;
          uint64_t nv = handout_resolve(he.id);
          if (!nv) { if (nunres++ < 4) LOG("【红】即时存档恢复：交出的宿主指针 %#llx（%s）在本版解析不了", (unsigned long long)he.v, he.id); continue; }
          s2a_snap_handout_id(nv, he.id);   // 本进程的值按原身份登记：恢复局里再存时这些指针照样能换算
          if (nv == he.v) { nsame++; continue; }
          from[k2] = he.v; to[k2++] = nv; }
      nm = k2;
      // 段：按名字找本进程的同名段；长度不同 = 布局变了，段内指针不能换算
      int na = 0; struct { uint64_t lo, n; char name[32]; } ar[64];
      if (hf && fread(&na, sizeof na, 1, hf) == 1 && na >= 0 && na <= 64 && fread(ar, sizeof ar[0], (size_t)na, hf) == (size_t)na) {
          pthread_mutex_lock(&g_ho_mu);
          for (int q = 0; q < na; q++) { ar[q].name[31] = 0; int hit = -1; for (int b = 0; b < g_nhor; b++) if (!strcmp(g_hor[b].name, ar[q].name)) hit = b;
              if (hit < 0 || g_hor[hit].n != ar[q].n) { LOG("【红】即时存档恢复：交出的宿主数据段「%s」在本版%s", ar[q].name, hit < 0 ? "没有" : "长度不同"); hobad++; continue; }
              if (g_hor[hit].lo == ar[q].lo) continue;
              rg[2 * nr2] = ar[q].lo; rg[2 * nr2 + 1] = ar[q].n; rgto[nr2++] = g_hor[hit].lo; }
          pthread_mutex_unlock(&g_ho_mu);
      } else if (mg == HO_MAGIC) { LOG("【红】即时存档恢复：交出的宿主数据段表读不了"); hobad++; }
      if (hf) fclose(hf);
      if (nunres) hobad++;
      while (hcap < nm * 4 + 4) hcap <<= 1; hk = calloc(hcap, 8); hv = calloc(hcap, 8);
      for (size_t i = 0; i < nm; i++) { size_t j = (from[i] * 0x9E3779B97F4A7C15ull) >> 40 & (hcap - 1); while (hk[j]) j = (j + 1) & (hcap - 1); hk[j] = from[i]; hv[j] = to[i]; } }
    uint64_t lo = ~0ull, hi = 0; for (size_t i = 0; i < nm; i++) { if (from[i] < lo) lo = from[i]; if (from[i] > hi) hi = from[i]; }
    if (!nm) { lo = 1; hi = 0; }
    const int fix = nm || nr2;
    // 一段内存里的宿主指针按对照表换算，回替换了几处（经文件写的段在缓冲里换算、原地写的段在目标地址换算，结果相同）
    uint64_t (^ptrfix)(uint64_t *, size_t) = ^uint64_t(uint64_t *p, size_t nw) {
        uint64_t k = 0;
        for (size_t w = 0; w < nw; w++) { uint64_t x = p[w];
            for (int q = 0; q < nr2; q++) if (x >= rg[2 * q] && x < rg[2 * q] + rg[2 * q + 1]) { p[w] = rgto[q] + (x - rg[2 * q]); k++; x = 0; break; }
            if (!x || x < lo || x > hi) continue; size_t j = (x * 0x9E3779B97F4A7C15ull) >> 40 & (hcap - 1);
            while (hk[j]) { if (hk[j] == x) { p[w] = hv[j]; k++; break; } j = (j + 1) & (hcap - 1); } }
        return k;
    };
    // 写回：固定几个工作线程按序领记录，每个线程一块缓冲（记录最长 8 MB，见 dump_mem 的 CH）
    __block int bad = 0, wbad = 0; __block uint64_t nrep = 0; __block int next = 0;
    size_t nwk = (size_t)sysconf(_SC_NPROCESSORS_ONLN); if (nwk < 1) nwk = 1; if (nwk > 16) nwk = 16;
    uint64_t bufn = 0; for (int i = 0; i < nr; i++) if (viaf[i] && rv[i].n > bufn) bufn = rv[i].n;
    dispatch_apply(nwk, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t wk) {
        (void)wk; uint8_t *buf = NULL; uint64_t k = 0;
        for (;;) { int i = __atomic_fetch_add(&next, 1, __ATOMIC_RELAXED); if (i >= nr) break;
            if (!viaf[i]) {
                if (rv[i].cl == rv[i].n) memcpy((void *)rv[i].a, rv[i].d, rv[i].n);
                else if (compression_decode_buffer((uint8_t *)rv[i].a, rv[i].n, rv[i].d, rv[i].cl, NULL, COMPRESSION_LZ4) != rv[i].n) { __atomic_add_fetch(&bad, 1, __ATOMIC_RELAXED); continue; }
                if (fix) k += ptrfix((uint64_t *)rv[i].a, rv[i].n / 8);
                continue; }
            if (!buf && !(buf = malloc(bufn))) { __atomic_add_fetch(&wbad, 1, __ATOMIC_RELAXED); continue; }
            const uint8_t *src = rv[i].d;
            if (rv[i].cl != rv[i].n) { if (compression_decode_buffer(buf, rv[i].n, rv[i].d, rv[i].cl, NULL, COMPRESSION_LZ4) != rv[i].n) { __atomic_add_fetch(&bad, 1, __ATOMIC_RELAXED); continue; } src = buf; }
            if (fix) { if (src != buf) { memcpy(buf, src, rv[i].n); src = buf; } k += ptrfix((uint64_t *)buf, rv[i].n / 8); }
            off_t off = (off_t)foff[i]; uint64_t done = 0;
            while (done < rv[i].n) { ssize_t w = pwrite(gfd, src + done, (size_t)(rv[i].n - done), off + (off_t)done); if (w <= 0) { if (w < 0 && errno == EINTR) continue; break; } done += (uint64_t)w; }
            if (done != rv[i].n) __atomic_add_fetch(&wbad, 1, __ATOMIC_RELAXED);
        }
        free(buf); if (k) __atomic_add_fetch(&nrep, k, __ATOMIC_RELAXED);
    });
    double tp1 = now_s();
    if (wbad) LOG("【红】即时存档恢复：页内容经后备文件写回失败 %d 段（errno %d）", wbad, errno);
    LOG("%s即时存档恢复：交出的宿主指针按身份换算 %llu 个（同址 %llu、解析不了 %llu），数据段 %d 段，游戏内存里替换 %llu 处", nunres ? "【红】" : "", (unsigned long long)nm, (unsigned long long)nsame, (unsigned long long)nunres, nr2, (unsigned long long)nrep);
    LOG("即时存档恢复：页内容拆账 映射核对 + 放开写 %.2f、写回 + 指针换算 %.2f（秒）；经后备文件写 %d 段 %.0f MB、经映射写 %d 段", tp0 - t_lm0, tp1 - tp0, nviaf, bviaf / 1048576.0, nr - nviaf);
    free(hk); free(hv); free(from); free(to); free(rg); free(rgto); free(viaf); free(foff); bad += wbad;
    {   // 布局变了的游戏内存对象：写回全部完成后按地址排序、相邻并段，整片找一遍原地转（没有要转的直接返回）
        int need = 0; for (int i = 0; i < g_nconv; i++) need |= g_conv[i].magic != 0;
        uint64_t *gr = need && !bad ? malloc(16 * (size_t)(nr ? nr : 1)) : NULL; int ng = 0;
        if (gr) { int (^cmp)(const void *, const void *) = ^int(const void *x, const void *y) { uint64_t u = ((const rec_t *)x)->a, w = ((const rec_t *)y)->a; return u < w ? -1 : u > w; };
            qsort_b(rv, (size_t)nr, sizeof *rv, cmp);
            for (int i = 0; i < nr; i++) { if (ng && gr[2 * ng - 2] + gr[2 * ng - 1] == rv[i].a) gr[2 * ng - 1] += rv[i].n; else { gr[2 * ng] = rv[i].a; gr[2 * ng + 1] = rv[i].n; ng++; } }
            conv_guest_objs(gr, ng); free(gr); } }
    munmap(m, (size_t)st.st_size); free(rv); *raw_out = raw;
    LOG("%s即时存档恢复：页内容 %d 段 %.0f MB 写回（放开写 %d 段，解压失败 %d）", bad ? "【红】" : "", nr, raw / 1048576.0, fixed, bad);
    return bad || hobad ? -1 : 0;
}
// 起好服务层之后、本该起游戏主线程的位置调：成功回 0（游戏线程已按快照续跑）；失败回 -1（调用方当场退出：此时还没有游戏线程在跑、没写过存档目录）
int nvn_snap_redump(const char *dir) __attribute__((weak_import));   // 诊断：恢复后 5 秒重存一遍显卡内容，和快照逐张对比（S2A_SNAP_REDUMP=1）
static void *grab_thread(void *arg) {
    const char *d = arg; static const int at[3] = {1, 5, 20}; int prev = 0;
    for (int i = 0; i < 3; i++) { sleep((unsigned)(at[i] - prev)); prev = at[i]; char g[2200]; snprintf(g, sizeof g, "%s/b_after_%02ds.png", d, at[i]); if (nvn_snap_grab) nvn_snap_grab(g);
        if (at[i] == 5 && getenv("S2A_SNAP_REDUMP") && nvn_snap_redump) nvn_snap_redump(d); }
    LOG("即时存档恢复：验证截图已存（%s/b_after_*.png）", d); return NULL;
}
int s2a_snap_restore(const char *dir) {
    {   // 动态装载的 NRO：先按快照顺序重新装（落点与存档时相同），再核模块落点、写回游戏内存
        int s2a_snap_nro_preload(FILE *); FILE *nf = open_in(dir, "nro.bin", "rb");
        if (!nf) { LOG("【红】即时存档恢复：快照缺动态模块表（nro.bin）"); return -1; }
        int r = s2a_snap_nro_preload(nf); fclose(nf); if (r) return -1; }
    {   // 模块落点必须与快照时逐个相同（维护者：补丁岛变长跨 2 MB、窗口起点不同都会让模块整体移位；按记录比，不按升级路径推断）
        extern module_t *g_mod; extern int g_nmod; char v[256]; int want = -1, bad = 0;
        if (!man_get(dir, "模块数", v, sizeof v)) want = atoi(v);
        if (want != g_nmod) { LOG("【红】即时存档恢复：游戏模块数与快照时不同（快照 %d，当前 %d）：这个快照是旧版存的，布局接不上；游戏自己的存档不受影响", want, g_nmod); s2a_snap_mark_old(); return -1; }
        for (int i = 0; i < g_nmod; i++) { char k[32]; snprintf(k, sizeof k, "模块%d", i); char cur[256];
            snprintf(cur, sizeof cur, "%s\t%llu\t%llu", g_mod[i].name, (unsigned long long)(uintptr_t)g_mod[i].base, (unsigned long long)g_mod[i].size);
            if (man_get(dir, k, v, sizeof v) || strcmp(v, cur)) { LOG("【红】即时存档恢复：游戏模块 %d 落点与快照时不同（快照 %s，当前 %s）", i, v, cur); bad++; } }
        if (bad) { LOG("【红】即时存档恢复：这个快照是旧版存的，模块布局接不上，拒绝恢复；游戏自己的存档不受影响"); s2a_snap_mark_old(); return -1; }
        LOG("即时存档恢复：游戏模块 %d 个落点与快照时逐个相同", g_nmod); }
    {   // 服务层已起：它实际用的数据根必须就是快照时的那个（校验阶段按清单里记的算了存档目录哈希），不同就停下、什么都不写
        char d[2048] = "", pv[2048] = ""; if (S2A_SnapDataRoot && S2A_SnapDataRoot(d, sizeof d) > 0) root_portable(d, pv, sizeof pv);
        if (g_root_hint_v[0] && strcmp(pv, g_root_hint_v)) { LOG("【红】即时存档恢复：服务层数据根与快照时不同（快照 %s，当前 %s），停下", g_root_hint_v, pv); return -1; } }
    double t0 = now_s(); char st0[80]; int sn0; save_dir_hash(st0, &sn0);
    FILE *f = open_in(dir, "svcmem.bin", "rb"); if (!f || s2a_snap_svcmem_load(f)) { if (f) fclose(f); return -1; } fclose(f);
    { int s2a_snap_far_load(FILE *); f = open_in(dir, "far.bin", "rb"); if (!f || s2a_snap_far_load(f)) { if (f) fclose(f); return -1; } fclose(f); }
    double t1 = now_s(); uint64_t raw = 0;
    int s2a_snap_keypages_reapply(void);
    if (load_mem(dir, &raw) || s2a_snap_hostslots_reapply() || s2a_snap_keypages_reapply()) return -1;
    double t2 = now_s();
    f = open_in(dir, "hlog.bin", "rb"); if (!f || s2a_snap_hlog_load(f)) { if (f) fclose(f); LOG("【红】即时存档恢复：读不了句柄日志"); return -1; } fclose(f);
    f = open_in(dir, "kernel.bin", "rb"); if (!f || s2a_snap_kernel_load(f, s2a_snap_skip_cs)) { if (f) fclose(f); return -1; } fclose(f);
    double t3 = now_s();
    s2a_snap_replay_prelude();
    uint64_t sc = scratch_pick(64ull << 20); if (!sc) { LOG("【红】即时存档恢复：窗口里找不到重放暂存区"); return -1; }
    char ip[2048]; snprintf(ip, sizeof ip, "%s/ipc.bin", dir);
    int rbad = S2A_SnapReplay ? S2A_SnapReplay(ip, sc, 64ull << 20) : -1;
    scratch_done(sc, 64ull << 20);
    if (rbad < 0) return -1;
    double t4 = now_s();
    if (s2a_snap_defer_finish() || s2a_snap_kernel_post() || s2a_snap_svcmem_shared()) return -1;
    { char p[2048]; snprintf(p, sizeof p, "%s/audio.bin", dir); if (!S2A_SnapAudioRestore || S2A_SnapAudioRestore(p)) { LOG("【红】即时存档恢复：音频渲染器状态没拷回"); return -1; } }
    double t4a = now_s();   // 「核对」拆账（11-17 iPhone 大金刚这一段 1.09 s，Mac 0.08 s）：服务收尾 + 音频 / 权限 / 图形 / 存档树各计各的
    s2a_snap_svcmem_perms();
    double t4b = now_s();
    if (!nvn_snap_restore || nvn_snap_restore(dir)) { LOG("【红】即时存档恢复：图形状态没恢复"); return -1; }
    double t4c = now_s();
    char st1[80]; int sn1; save_dir_hash(st1, &sn1);
    if (strcmp(st0, st1)) { LOG("【红】即时存档恢复：恢复过程中已提交的存档变了（%.12s… → %.12s…），停下不起游戏线程", st0, st1); return -1; }
    { char src[2048], want[256], full[80]; int fn; snprintf(src, sizeof src, "%s/save_tree", dir);
      if (save_tree_put(src)) return -1;
      save_full_hash(full, &fn);
      if (man_get(dir, "存档全量", want, sizeof want) || strcmp(want, full)) { LOG("【红】即时存档恢复：写回后存档树与快照时不一致（快照 %.12s…，当前 %.12s…），停下", want, full); return -1; }
      LOG("即时存档恢复：存档树与快照时一致（%d 个文件 %.12s…）", fn, full); }
    double t5 = now_s();
    LOG("即时存档恢复：核对拆账 服务收尾 + 音频 %.2f、内存权限 %.2f、图形 %.2f、存档树 %.2f（秒）", t4a - t4, t4b - t4a, t4c - t4b, t5 - t4c);
    if (s2a_snap_threads_start()) return -1;
    double t6 = now_s();
    snap_live_after_restore();   // 游戏线程放开之前接上日志：放开后第一条新请求就记在快照日志之后
    s2a_snap_unfreeze();
    {   // 验证用：恢复后第 1 / 5 / 20 秒的画面（另起线程，不挡游戏）
        static char gdir[2048]; s2a_docs_root(gdir, sizeof gdir);
        pthread_t th; pthread_create(&th, NULL, grab_thread, gdir); pthread_detach(th);
    }
    LOG("即时存档恢复：完成，合计 %.2f s（内存账 %.2f、页内容 %.0f MB %.2f、内核账 %.2f、服务重放 %.2f（异常 %d 条）、核对 %.2f、起线程 %.2f）；存档目录前后一致（%d 个文件 %.12s…）",
        t6 - t0, t1 - t0, raw / 1048576.0, t2 - t1, t3 - t2, t4 - t3, rbad, t5 - t4, t6 - t5, sn1, st1);
    return 0;
}
