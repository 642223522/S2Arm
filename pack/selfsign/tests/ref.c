// 对照用：手机端签法（runtime/src/selfsign.c，真机验过）给同一份 dylib 签名，供 tests/pc_selfsign_test.sh 与 s2a-selfsign 逐块比。
//   ref <p12> <密码> <团队号> <包名> <输入> <输出>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n);
static unsigned char *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)l); if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f); *n = (size_t)l; return b;
}
int main(int argc, char **argv) {
    if (argc != 7) { fprintf(stderr, "ref <p12> <密码> <团队号> <包名> <输入> <输出>\n"); return 2; }
    size_t pn, n; unsigned char *p12 = slurp(argv[1], &pn), *in = slurp(argv[5], &n);
    if (!p12 || !in) { fprintf(stderr, "读不了输入\n"); return 1; }
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    if (s2a_selfsign_identity(p12, pn, argv[2], &key, &chain)) { fprintf(stderr, "p12 读不了\n"); return 1; }
    char appid[512]; snprintf(appid, sizeof appid, "%s.%s", argv[3], argv[4]);
    uint8_t *out = NULL; size_t on = 0; char why[300] = "";
    if (s2a_selfsign_macho(in, n, NULL, argv[3], appid, key, chain, &out, &on, why, sizeof why)) { fprintf(stderr, "签名失败：%s\n", why); return 1; }
    FILE *f = fopen(argv[6], "wb"); if (!f || fwrite(out, 1, on, f) != on) { fprintf(stderr, "写不进输出\n"); return 1; } fclose(f);
    return 0;
}
