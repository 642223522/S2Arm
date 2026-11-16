// D-WQPH（11-15）：SetShaders 时代码区还不在已登记内存池里的 Switch 1 着色器，到首用（prog_key）才算出键，也要交给首遇现编登记（dm_shader_miss）。
//   修前这类键不进待编表，dm_shader_miss_late 对 Switch 1 只认待编表，不在库里的整支丢、不现编（Mac 奥日2 1.2.0 每局 18–136 支）。
//   判据借 DM_NVN_SHDUMP：dm_shader_miss 认出阶段就把 <键>.ctl / .code 存进这个目录（dsh_miss.inc dsh_dump），所以「目录里出现这个键的 .ctl」= 登记入口被调到了。
//   ① SetShaders：代码区是普通堆内存（不在任何内存池）→ 不取键、目录为空；② 首用 prog_key → 算出键、目录里出现 <键>.ctl；③ 再取一次键不重复登记（文件只写一次，不再改）。
#include "nvn_protos.h"
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int prog_key(const void *p, unsigned stage, uint8_t key[8]);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

static int count_files(const char *dir) { int n = 0; DIR *d = opendir(dir); struct dirent *e; if (!d) return -1; while ((e = readdir(d))) if (e->d_name[0] != '.') n++; closedir(d); return n; }

int main(void) {
    char dir[] = "/tmp/t_nvn_late_key.XXXXXX"; if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_NVN_SHDUMP", dir, 1); unsetenv("DM_MSL_FALLBACK");
    NVNT_nvnProgramSetShaders set = (NVNT_nvnProgramSetShaders)h_nvnBootstrapLoader("nvnProgramSetShaders");
    if (!set) { printf("✗ 找不到 nvnProgramSetShaders\n"); return 1; }

    // Switch 1 控制段：自报长度 0x880（+0x20）、代码长 64（+0x704）；代码区首字不是图形头 → 计算阶段（dsh_stage）
    uint8_t *ctl = calloc(1, 0x880), *code = calloc(1, 64);
    uint32_t nctl = 0x880, ncode = 64; memcpy(ctl + 0x20, &nctl, 4); memcpy(ctl + 0x704, &ncode, 4);
    for (int i = 0; i < 64; i++) code[i] = (uint8_t)(i * 7 + 1);
    union { NVNprogram p; char raw[256]; } prog; memset(&prog, 0, sizeof prog);
    NVNshaderData sd = { (NVNbufferAddress)(uintptr_t)code, ctl };

    // ① SetShaders：代码区不在内存池 → 不取键、不登记
    CHECK(set(&prog.p, 1, &sd), "SetShaders 返回失败");
    CHECK(count_files(dir) == 0, "① SetShaders 时代码区不在内存池，不该登记，目录里却有 %d 个文件", count_files(dir));

    // ② 首用取键 → 登记（目录里出现 <键>.ctl / .code）
    uint8_t key[8]; CHECK(prog_key(&prog.p, 0, key) == 1, "② prog_key 没给出键");
    char hx[17]; for (int i = 0; i < 8; i++) snprintf(hx + 2 * i, 3, "%02x", key[i]);
    char path[512]; struct stat st;
    snprintf(path, sizeof path, "%s/%s.ctl", dir, hx); int have_ctl = !stat(path, &st) && st.st_size == 0x880;
    snprintf(path, sizeof path, "%s/%s.code", dir, hx); int have_code = !stat(path, &st) && st.st_size == 64;
    CHECK(have_ctl && have_code, "② 首用算出键 %s 后没交给首遇现编登记（%s.ctl %s、.code %s）", hx, hx, have_ctl ? "有" : "无", have_code ? "有" : "无");

    // ③ 再取一次：键已算过，不再登记（目录文件数不变）
    int before = count_files(dir); uint8_t key2[8]; prog_key(&prog.p, 0, key2);
    CHECK(!memcmp(key, key2, 8) && count_files(dir) == before, "③ 第二次取键应与第一次相同且不再登记（文件 %d → %d）", before, count_files(dir));

    char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    printf("%s t_nvn_late_key：SetShaders 时代码区不在内存池的着色器，首用取键时交给首遇现编登记 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
