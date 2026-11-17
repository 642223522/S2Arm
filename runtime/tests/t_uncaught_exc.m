// t_uncaught_exc：ios/uncaught_exc.m 装的未捕获异常处理。期望手写：子进程在主队列的块里抛 NSException（名 S2ATestExc、原因 probe-reason、userInfo k=v），
//   不捕获 → 子进程异常结束；它的输出里应有「未捕获的 ObjC 异常：S2ATestExc：probe-reason」「异常 userInfo」与至少一行「异常栈」。
//   反证：不链 ios/uncaught_exc.m（或删掉构造函数）→ 这三行都没有
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    if (argc > 1) {   // 子进程：主队列里抛，同 GameController 在 dispatch 主队列回调里抛的路径
        dispatch_async(dispatch_get_main_queue(), ^{ @throw [NSException exceptionWithName:@"S2ATestExc" reason:@"probe-reason" userInfo:@{@"k": @"v"}]; });
        dispatch_main();
    }
    int fd[2]; if (pipe(fd)) return 2;
    pid_t pid = fork();
    if (!pid) { dup2(fd[1], 2); dup2(fd[1], 1); close(fd[0]); execl(argv[0], argv[0], "child", (char *)NULL); _exit(3); }
    close(fd[1]);
    static char out[65536]; size_t n = 0; ssize_t r;
    while (n < sizeof out - 1 && (r = read(fd[0], out + n, sizeof out - 1 - n)) > 0) n += (size_t)r;
    out[n] = 0; int st = 0; waitpid(pid, &st, 0);
    int bad = 0;
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) { printf("✗ 子进程抛了未捕获异常却正常退出\n"); bad++; }
    if (!strstr(out, "未捕获的 ObjC 异常：S2ATestExc：probe-reason")) { printf("✗ 没记下异常名与原因\n"); bad++; }
    if (!strstr(out, "异常 userInfo：")) { printf("✗ 没记下 userInfo\n"); bad++; }
    if (!strstr(out, "异常栈 ")) { printf("✗ 没记下调用栈\n"); bad++; }
    if (bad) printf("子进程输出：\n%.2000s\n", out);
    printf("%s t_uncaught_exc：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
