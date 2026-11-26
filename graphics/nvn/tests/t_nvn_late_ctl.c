// D-K3DA（11-17，0.5.7 iPhone 奥日2）：SetShaders 时代码区还不在已登记内存池的 Switch 1 着色器，键留到首用（prog_key）才算；
//   控制段只在 SetShaders 这次调用里保证有效，游戏随后复用那块内存，首用时读到别的数据：键对不上库、代码长度取错（+0x704 成了 0x76），现编越界失败。
//   期望：SetShaders 之后把游戏那块控制段整块改掉，首用算出的键仍等于「SetShaders 时的控制段 0x880 字节 + 代码区」的 SHA-256 前 8 字节（键规则同 hle_nvn.c keys_hash，期望在这里手算）。
//   不开 DM_NVN_SHDUMP：诊断档本来就整份拷控制段，开着测不出（t_nvn_late_key 就是开着的）。
//   ② 两个程序用内容相同的控制段：各自首用的键相同（去重拷贝不串内容）
//   ③ Switch 2（NVN2 控制段，键一律首用才算）：同样把控制段改掉，键仍等于 SetShaders 时控制段前 0x48 字节（+0x20..+0x28、+0x30..+0x34 清零）+ 代码区的 SHA-256 前 8 字节
//      （#1520：一款 Switch 2 游戏 108 支现编失败里 98 支的「控制段」连 NVN2 魔数都没有）。喂一份假 NPDM（ACID 在 +0x300）打开 Switch 2 路径，所以放最后
#include "nvn_protos.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int prog_key(const void *p, unsigned stage, uint8_t key[8]);
extern uint64_t s2a_npdm_pid(const char *npdm);
extern int nvn2_on(void);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

static void hex(const uint8_t *k, char *o) { for (int i = 0; i < 8; i++) snprintf(o + 2 * i, 3, "%02x", k[i]); }

int main(void) {
    unsetenv("DM_NVN_SHDUMP"); unsetenv("DM_MSL_FALLBACK");
    NVNT_nvnProgramSetShaders set = (NVNT_nvnProgramSetShaders)h_nvnBootstrapLoader("nvnProgramSetShaders");
    if (!set) { printf("✗ 找不到 nvnProgramSetShaders\n"); return 1; }
    // Switch 1 控制段：魔数 0x98761234、版本 1、自报长度 0x880（+0x20）、代码长 64（+0x704）；代码区是普通堆内存（不在任何内存池）
    uint8_t *ctl = calloc(1, 0x880), *orig = malloc(0x880), *code = calloc(1, 64);
    uint32_t magic = 0x98761234u, ver = 1, nctl = 0x880, ncode = 64;
    memcpy(ctl, &magic, 4); memcpy(ctl + 4, &ver, 4); memcpy(ctl + 0x20, &nctl, 4); memcpy(ctl + 0x704, &ncode, 4);
    for (int i = 0x40; i < 0x700; i++) ctl[i] = (uint8_t)(i * 13 + 5);
    for (int i = 0; i < 64; i++) code[i] = (uint8_t)(i * 7 + 1);
    memcpy(orig, ctl, 0x880);
    uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX c; CC_SHA256_Init(&c); CC_SHA256_Update(&c, orig, 0x880); CC_SHA256_Update(&c, code, 64); CC_SHA256_Final(md, &c);
    char want[17], got[17]; hex(md, want);

    union { NVNprogram p; char raw[256]; } prog; memset(&prog, 0, sizeof prog);
    NVNshaderData sd = { (NVNbufferAddress)(uintptr_t)code, ctl };
    CHECK(set(&prog.p, 1, &sd), "SetShaders 返回失败");
    memset(ctl, 0x5a, 0x880);   // 游戏复用了控制段那块内存
    uint8_t key[8] = {0}; CHECK(prog_key(&prog.p, 0, key) == 1, "① prog_key 没给出键");
    hex(key, got);
    CHECK(!memcmp(key, md, 8), "① 控制段被复用后首用取键：期望 %s（SetShaders 时的控制段 + 代码），得到 %s", want, got);

    // ② 第二个程序、同内容控制段（另一块内存）：键相同
    uint8_t *ctl2 = malloc(0x880); memcpy(ctl2, orig, 0x880);
    union { NVNprogram p; char raw[256]; } prog2; memset(&prog2, 0, sizeof prog2);
    NVNshaderData sd2 = { (NVNbufferAddress)(uintptr_t)code, ctl2 };
    CHECK(set(&prog2.p, 1, &sd2), "② SetShaders 返回失败");
    memset(ctl2, 0x33, 0x880);
    uint8_t key2[8] = {0}; prog_key(&prog2.p, 0, key2); hex(key2, got);
    CHECK(!memcmp(key2, md, 8), "② 同内容控制段的第二个程序：期望 %s，得到 %s", want, got);

    // ③ Switch 2
    {
        char np[] = "/tmp/t_nvn_late_ctl_npdm.XXXXXX"; int fd = mkstemp(np); uint8_t npdm[0x80 + 0x304] = {0};
        memcpy(npdm, "META", 4); uint32_t acid = 0x80; memcpy(npdm + 0x78, &acid, 4); memcpy(npdm + 0x80 + 0x300, "ACID", 4);
        FILE *nf = fdopen(fd, "wb"); fwrite(npdm, 1, sizeof npdm, nf); fclose(nf);
        s2a_npdm_pid(np); unlink(np);
        CHECK(nvn2_on(), "③ 假 NPDM 没打开 Switch 2 路径");
        uint8_t *c2 = calloc(1, 0xe0), *o2 = malloc(0xe0), *code2 = calloc(1, 128);
        uint32_t m2 = 0x98761234u, v2 = 0xc9, own = 0xe0, n2 = 128; memcpy(c2, &m2, 4); memcpy(c2 + 4, &v2, 4); memcpy(c2 + 0x30, &own, 4); memcpy(c2 + 0x44, &n2, 4);
        c2[0x56] = 5;   // 阶段字节：计算
        for (int i = 0x08; i < 0x20; i++) c2[i] = (uint8_t)(i * 3 + 1);
        for (int i = 0x48; i < 0x56; i++) c2[i] = (uint8_t)(i * 5 + 2);
        for (int i = 0; i < 128; i++) code2[i] = (uint8_t)(i * 11 + 3);
        memcpy(o2, c2, 0xe0);
        uint8_t kc[0x48]; memcpy(kc, o2, 0x48); memset(kc + 0x20, 0, 8); memset(kc + 0x30, 0, 4);
        uint8_t md2[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX c3; CC_SHA256_Init(&c3); CC_SHA256_Update(&c3, kc, 0x48); CC_SHA256_Update(&c3, code2, 128); CC_SHA256_Final(md2, &c3);
        char want2[17]; hex(md2, want2);
        union { NVNprogram p; char raw[256]; } p3; memset(&p3, 0, sizeof p3);
        NVNshaderData sd3 = { (NVNbufferAddress)(uintptr_t)code2, c2 };
        CHECK(set(&p3.p, 1, &sd3), "③ SetShaders 返回失败");
        memset(c2, 0x77, 0xe0);   // 游戏复用了控制段那块内存
        uint8_t k3[8] = {0}; prog_key(&p3.p, 0, k3); hex(k3, got);
        CHECK(!memcmp(k3, md2, 8), "③ Switch 2 控制段被复用后首用取键：期望 %s，得到 %s", want2, got);
    }

    printf("%s t_nvn_late_ctl：首用才算键的着色器用 SetShaders 时的控制段 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
