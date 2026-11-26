// 停帧救场「这款下次也关」的起局读取（docs_android.c s2a_android_stall_off_apply）。期望按口径手写（同 Mac pack/jobs/cheats.py note_stall：
//   有标记 = 这款帧率写关）：没标记不动环境；有标记且启动环境没给 S2A_FPS60 → 写 0；启动环境给了就不覆盖；标记是目录 / 没有文档根都按没标记
#include "docs_android.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fails;
static void expect(int ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL %s\n", what); fails++; } }
static int env_is(const char *v) { const char *e = getenv("S2A_FPS60"); return v ? e && !strcmp(e, v) : !e; }

int main(void) {
    char dir[] = "/tmp/s2a-stall-off-XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    char mark[256]; snprintf(mark, sizeof mark, "%s/cpatch_stall_off", dir);

    unsetenv("S2A_FPS60");
    expect(s2a_android_stall_off_apply(dir) == 0 && env_is(NULL), "no mark: 0, environment untouched");
    expect(s2a_android_stall_off_apply(NULL) == 0 && s2a_android_stall_off_apply("") == 0 && env_is(NULL), "no docs root: 0");

    FILE *f = fopen(mark, "w"); fputs("fps\n", f); fclose(f);
    expect(s2a_android_stall_off_apply(dir) == 1 && env_is("0"), "mark: 1, S2A_FPS60=0");
    expect(access(mark, F_OK) == 0, "mark is kept (it is this game's frame-rate off)");

    setenv("S2A_FPS60", "1", 1);
    expect(s2a_android_stall_off_apply(dir) == 2 && env_is("1"), "launch environment gave S2A_FPS60: 2, not overwritten");

    unsetenv("S2A_FPS60"); unlink(mark); mkdir(mark, 0700);
    expect(s2a_android_stall_off_apply(dir) == 0 && env_is(NULL), "mark path is a directory: treated as no mark");
    rmdir(mark); rmdir(dir);
    if (fails) return 1;
    puts("stall_off_test: ok (6 checks)");
    return 0;
}
