// 手机端自签（runtime/src/selfsign.c）的权限输出：与系统 codesign 逐字节对照（只 Mac）。
//   期望值不靠被测实现：同一份权限（application-identifier / team-identifier）交给 codesign --entitlements，取它写出的
//   XML 权限槽（类型 5，magic 0xfade7171）与 DER 权限槽（类型 7，magic 0xfade7172）当真值。
//   ① 带 appid：两槽与 codesign 逐字节一致；CodeDirectory 特殊槽 -5 / -7 = 两槽的 SHA-256；签名标识 = appid 去掉团队号前缀；codesign -v 通过
//   ② 不带 appid：与 codesign 不带 --entitlements 一样没有 5 / 7 两槽，特殊槽只有 2 个；签名标识沿用原签名；codesign -v 通过
//   证书：测试时用 openssl 现生成一张自签名证书打成 p12（不用任何真证书；要带代码签名用途，否则 codesign -v 报 Invalid Key Usage）；输入：现编的 arm64 小可执行文件（ad-hoc 签名）
#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "s2a_t_result.h"

int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain);
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n);
void s2a_log_line(const char *fmt, ...) { (void)fmt; }

static int fails;
#define CHECK(c, ...) do { if (c) printf("通 " __VA_ARGS__); else { printf("【红】 " __VA_ARGS__); fails++; } printf("\n"); } while (0)

static uint32_t be(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint8_t *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = l > 0 ? malloc((size_t)l) : NULL; if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f); *n = (size_t)l; return b;
}
static int sh(const char *fmt, const char *dir) { char c[2048]; snprintf(c, sizeof c, fmt, dir, dir, dir, dir, dir, dir); return system(c); }

// 取签名 SuperBlob 里某类型的 blob（含 8 字节头）；没有返回 NULL
static const uint8_t *blob(const uint8_t *f, size_t n, uint32_t type, uint32_t *len) {
    const uint8_t *sb = NULL;
    for (size_t i = n >= 12 ? n - 12 : 0; i > 0; i--) if (be(f + i) == 0xfade0cc0 && i + be(f + i + 4) <= n) { sb = f + i; break; }   // 签名在文件尾，从后往前找
    if (!sb) return NULL;
    for (uint32_t k = 0, c = be(sb + 8); k < c; k++) if (be(sb + 12 + k * 8) == type) { const uint8_t *b = sb + be(sb + 16 + k * 8); *len = be(b + 4); return b; }
    return NULL;
}

static void one_case(const char *dir, SecKeyRef key, CFArrayRef chain, const uint8_t *in, size_t n, const char *appid) {
    const char *tag = appid ? "带 appid" : "不带 appid";
    // 真值：codesign
    char ref[512]; snprintf(ref, sizeof ref, "%s/ref_%s", dir, appid ? "ent" : "plain");
    char cmd[2048];
    if (appid) snprintf(cmd, sizeof cmd, "cp %s/in %s && codesign -f -s - --entitlements %s/e.plist %s 2>/dev/null", dir, ref, dir, ref);
    else snprintf(cmd, sizeof cmd, "cp %s/in %s && codesign -f -s - %s 2>/dev/null", dir, ref, ref);
    CHECK(system(cmd) == 0, "%s：codesign 出真值", tag);
    size_t rn = 0; uint8_t *rf = slurp(ref, &rn);
    // 被测
    uint8_t *out = NULL; size_t on = 0; char why[256] = {0};
    int rc = s2a_selfsign_macho(in, n, NULL, "ABCDE12345", appid, key, chain, &out, &on, why, sizeof why);
    CHECK(rc == 0, "%s：签名成功 %s", tag, why);
    if (rc || !rf) { free(rf); free(out); return; }
    char ours[512]; snprintf(ours, sizeof ours, "%s/ours_%s", dir, appid ? "ent" : "plain");
    FILE *f = fopen(ours, "wb"); fwrite(out, 1, on, f); fclose(f);
    for (uint32_t t = 5; t <= 7; t += 2) {
        uint32_t la = 0, lb = 0; const uint8_t *a = blob(rf, rn, t, &la), *b = blob(out, on, t, &lb);
        if (appid) CHECK(a && b && la == lb && !memcmp(a, b, la), "%s：类型 %u 权限槽与 codesign 逐字节一致（%u / %u 字节）", tag, t, la, lb);
        else CHECK(!a && !b, "%s：类型 %u 权限槽两边都没有", tag, t);
    }
    uint32_t cl = 0; const uint8_t *cd = blob(out, on, 0, &cl);
    CHECK(cd && be(cd) == 0xfade0c02, "%s：有 CodeDirectory", tag);
    if (cd) {
        uint32_t hash_off = be(cd + 16), nspecial = be(cd + 24);
        CHECK(nspecial == (appid ? 7u : 2u), "%s：特殊槽 %u 个", tag, nspecial);
        if (appid && nspecial == 7) {
            for (uint32_t t = 5; t <= 7; t += 2) {
                uint32_t lb = 0; const uint8_t *b = blob(out, on, t, &lb); uint8_t h[32]; CC_SHA256(b, lb, h);
                CHECK(!memcmp(cd + hash_off - t * 32, h, 32), "%s：特殊槽 -%u = 权限槽的 SHA-256", tag, t);
            }
        }
        const char *id = (const char *)cd + be(cd + 20);
        if (appid) CHECK(!strcmp(id, strchr(appid, '.') + 1), "%s：签名标识 = 包名（%s）", tag, id);
        else CHECK(!strcmp(id, "t_selfsign_in"), "%s：签名标识沿用原签名（%s）", tag, id);
    }
    snprintf(cmd, sizeof cmd, "codesign -v %s 2>/dev/null", ours);
    CHECK(system(cmd) == 0, "%s：codesign -v 验过", tag);
    free(rf); free(out);
}

// ③ 签名身份交接（s2a_identity_import）：钥匙串换成桩（不碰本机钥匙串）。期望按文件与 openssl 算的 sha1：
//   齐了 → 返回 1、桩被调 1 次、current.json 里是证书 sha1、incoming/ 三份删掉；sha1 对不上 / 私钥坏 → -1、写 import_error.txt、incoming/ 留着、桩不调；没交 → 0
int s2a_identity_import(const char *home);
void s2a_identity_test_store(int (*f)(SecKeyRef, SecCertificateRef, char *, size_t));
static int g_store_n;
static int store_stub(SecKeyRef k, SecCertificateRef c, char *why, size_t n) { (void)why; (void)n; g_store_n += k && c; return 0; }
static int exists(const char *d, const char *f) { char p[700]; snprintf(p, sizeof p, "%s/%s", d, f); return access(p, F_OK) == 0; }
static void id_case(const char *dir, const char *tag, const char *sha_in_json, int corrupt_key, int want_rc, const char *real_sha) {
    char home[600], inc[700], c[2400]; snprintf(home, sizeof home, "%s/home_%s", dir, tag);
    snprintf(inc, sizeof inc, "%s/Library/Application Support/S2Arm/identity/incoming", home);
    snprintf(c, sizeof c, "mkdir -p '%s' && cp %s/key.der '%s/key.der' && cp %s/cert.der '%s/cert.der' && printf '{\"schema\": 1, \"team\": \"ABCDE12345\", \"cert_sha1\": \"%s\"}' > '%s/identity.json'",
             inc, dir, inc, dir, inc, sha_in_json, inc);
    system(c);
    if (corrupt_key) { char k2[700]; snprintf(k2, sizeof k2, "%s/key.der", inc); FILE *f = fopen(k2, "r+b"); if (f) { fseek(f, 4, SEEK_SET); fputs("\x05\x05\x05\x05", f); fclose(f); } }
    g_store_n = 0; int rc = s2a_identity_import(home);
    char idd[700]; snprintf(idd, sizeof idd, "%s/Library/Application Support/S2Arm/identity", home);
    if (want_rc == 1) {
        char cur[800]; snprintf(cur, sizeof cur, "%s/current.json", idd); size_t n = 0; FILE *f = fopen(cur, "rb"); char buf[400] = {0}; if (f) { n = fread(buf, 1, sizeof buf - 1, f); fclose(f); }
        CHECK(rc == 1 && g_store_n == 1 && n && strstr(buf, real_sha) && !strstr(buf, "BEGIN") && !exists(inc, "key.der") && !exists(inc, "identity.json"),
              "身份交接 %s：返回 %d（期望 1）、存钥匙串 %d 次、current.json 带 sha1 %s、incoming/ 删掉", tag, rc, g_store_n, real_sha);
    } else {
        CHECK(rc == want_rc && g_store_n == 0 && exists(idd, "import_error.txt") && exists(inc, "key.der") && exists(inc, "identity.json"),
              "身份交接 %s：返回 %d（期望 %d）、不存钥匙串、写了 import_error.txt、incoming/ 留着", tag, rc, want_rc);
    }
}
int main(void) {
    char dir[] = "/tmp/t_selfsign.XXXXXX"; if (!mkdtemp(dir)) { puts("【红】建不了临时目录"); return 1; }
    // 输入：arm64 小可执行文件，签名标识 t_selfsign_in；证书：自签名 RSA 2048，OU = 团队号
    int r = sh("printf 'int main(void){return 0;}' > %s/m.c && cc -arch arm64 -o %s/in %s/m.c && codesign -f -s - -i t_selfsign_in %s/in 2>/dev/null", dir)
         || sh("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=t_selfsign/OU=ABCDE12345'"
               " -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=critical,codeSigning' -keyout %s/k.pem -out %s/c.pem 2>/dev/null"
               " && openssl pkcs12 -export -inkey %s/k.pem -in %s/c.pem -out %s/id.p12 -passout pass:t -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null", dir);
    CHECK(r == 0, "备好输入与测试证书");
    FILE *e = NULL; { char p[512]; snprintf(p, sizeof p, "%s/e.plist", dir); e = fopen(p, "w"); }
    if (e) { fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n"
                   "\t<key>application-identifier</key>\n\t<string>ABCDE12345.io.example.selfsign.test</string>\n"
                   "\t<key>com.apple.developer.team-identifier</key>\n\t<string>ABCDE12345</string>\n</dict>\n</plist>\n", e); fclose(e); }
    char p[512]; size_t pn = 0, n = 0;
    snprintf(p, sizeof p, "%s/id.p12", dir); uint8_t *pb = slurp(p, &pn);
    snprintf(p, sizeof p, "%s/in", dir); uint8_t *in = slurp(p, &n);
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    int ir = pb ? s2a_selfsign_identity(pb, pn, "t", &key, &chain) : -1;
    CHECK(ir == 0, "导入测试 p12（%d）", ir);
    if (!ir && in) {
        one_case(dir, key, chain, in, n, "ABCDE12345.io.example.selfsign.test");
        one_case(dir, key, chain, in, n, NULL);
    }
    {   printf("③ 签名身份交接\n");
        s2a_identity_test_store(store_stub);
        char cmd[1600]; snprintf(cmd, sizeof cmd, "cd %s && openssl rsa -in k.pem -traditional -outform DER -out key.der 2>/dev/null && openssl x509 -in c.pem -outform DER -out cert.der && openssl dgst -sha1 -r cert.der | cut -c1-40 > sha.txt", dir);
        int pr = system(cmd); char sha[64] = {0}; { char p[600]; snprintf(p, sizeof p, "%s/sha.txt", dir); FILE *f = fopen(p, "r"); if (f) { if (fgets(sha, sizeof sha, f)) sha[strcspn(sha, "\n")] = 0; fclose(f); } }
        CHECK(pr == 0 && strlen(sha) == 40, "备好 PKCS#1 私钥 DER、证书 DER、openssl 算的证书 sha1 %s", sha);
        id_case(dir, "ok", sha, 0, 1, sha);
        id_case(dir, "badsha", "0000000000000000000000000000000000000000", 0, -1, sha);
        id_case(dir, "badkey", sha, 1, -1, sha);
        char home[600]; snprintf(home, sizeof home, "%s/home_none", dir); g_store_n = 0;
        CHECK(s2a_identity_import(home) == 0 && g_store_n == 0, "没交（没有 identity.json）：返回 0、不碰钥匙串");
        s2a_identity_test_store(NULL);
    }
    char c[600]; snprintf(c, sizeof c, "rm -rf %s", dir); system(c);
    return S2A_T_RESULT("t_selfsign", fails);
}
