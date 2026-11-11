// 同一棵树的 C# 编译串行（门禁用，tools/gate.sh 开头现编到 $L/bin/dotnet，各步 DOTNET 与 PATH 都指它）：
//   编译类子命令（build / publish / restore / pack / msbuild / test / clean）先拿 <仓库>/build/.dotnet_build.lock 的内核文件锁再 exec 真 dotnet，
//   锁的文件描述符随 exec 留在 dotnet 进程里，进程（及其子进程）退出即放；其余子命令（dotnet x.dll …）直接 exec。
//   为什么是 C 不是脚本（11-11）：脚本解释器 /bin/bash 受 SIP 保护，启动时清掉 DYLD_* 环境变量——services/tests/t_native_provider.sh
//   用 env DYLD_INSERT_LIBRARIES=… "$DOTNET" 注入原生符号，经脚本包装一层就丢了、服务层单测红。编出来的程序不受 SIP 限制，DYLD_* 原样传给真 dotnet。
//   关 MSBuild 常驻节点（MSBUILDDISABLENODEREUSE=1：常驻节点构建后仍攥着输出文件）；等锁每 30 秒打一行（免被无进展看门狗判挂死）。
//   真 dotnet：S2A_DOTNET_REAL，没给就找 ~/.dotnet/dotnet、再按 PATH 找（跳过自己）；锁文件：S2A_DOTNET_LOCK（tools/gate.sh 给，缺省不拿锁）
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

static const char *find_real(const char *self, char *out) {
    char me[PATH_MAX], c[PATH_MAX], r[PATH_MAX]; const char *home = getenv("HOME"), *path = getenv("PATH");
    if (!realpath(self, me)) { if (strchr(self, '/')) return NULL; me[0] = 0; }
    if (home) { snprintf(c, sizeof c, "%s/.dotnet/dotnet", home); if (access(c, X_OK) == 0 && realpath(c, r) && strcmp(r, me)) { snprintf(out, PATH_MAX, "%s", c); return out; } }
    for (const char *p = path; p && *p; ) {
        const char *e = strchr(p, ':'); size_t n = e ? (size_t)(e - p) : strlen(p);
        snprintf(c, sizeof c, "%.*s/dotnet", (int)n, p);
        if (n && access(c, X_OK) == 0 && realpath(c, r) && (!me[0] || strcmp(r, me))) { snprintf(out, PATH_MAX, "%s", c); return out; }
        p = e ? e + 1 : NULL; }
    return NULL; }

int main(int argc, char **argv) {
    const char *real = getenv("S2A_DOTNET_REAL"), *lk = getenv("S2A_DOTNET_LOCK");
    // 调用方用 env -i 只传 DOTNET（如启动器作业环境的单测）时 S2A_DOTNET_REAL 不在：自己找真 dotnet——~/.dotnet/dotnet，再按 PATH 找（跳过自己）
    static char found[PATH_MAX];
    if (!real || !*real) real = find_real(argv[0], found);
    if (!real) { fprintf(stderr, "dotnet_lock：找不到真 dotnet（没有 S2A_DOTNET_REAL、~/.dotnet/dotnet，PATH 里也没有别的 dotnet）\n"); return 127; }
    setenv("MSBUILDDISABLENODEREUSE", "1", 1);
    static const char *verbs[] = { "build", "publish", "restore", "pack", "msbuild", "test", "clean", NULL };
    int build = 0;
    for (int i = 0; argc > 1 && verbs[i]; i++) if (!strcmp(argv[1], verbs[i])) build = 1;
    if (build && lk && *lk) {
        int fd = open(lk, O_RDWR | O_CREAT, 0644);
        if (fd >= 0) {
            time_t t0 = time(NULL), last = t0;
            while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
                if (errno != EWOULDBLOCK && errno != EINTR) break;   // 锁不可用（文件系统不支持等）：不拿锁照跑
                time_t now = time(NULL);
                if (now - last >= 30) { last = now; fprintf(stderr, "等本树 C# 构建锁（%s）已 %ld 秒：别的步正在编 C#\n", lk, (long)(now - t0)); }
                usleep(200000);
            }
            if (time(NULL) - t0 >= 2) fprintf(stderr, "C# 构建锁：等了 %ld 秒\n", (long)(time(NULL) - t0));
        }
    }
    argv[0] = (char *)real;
    execv(real, argv);
    fprintf(stderr, "dotnet_lock：起不来 %s（%s）\n", real, strerror(errno));
    return 127;
}
