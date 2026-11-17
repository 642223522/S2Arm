// 手机端自签（0.6.0 通用壳，可行性验证）：在 iOS 上用玩家自己的开发证书（p12）给游戏程序库（Mach-O dylib，arm64 单架构）重新签名，
//   电脑不用签。只用 iOS 也有的系统接口：CommonCrypto（SHA-256）、Security（SecPKCS12Import / SecKeyCreateSignature）。
// 签名格式照 Apple 代码签名（与 codesign / rcodesign 同构）：
//   SuperBlob 0xfade0cc0 = CodeDirectory（v0x20400，SHA-256，16 KiB 页）+ 空 Requirements 集合 + CMS 签名（PKCS#7 SignedData，分离式）
//   CMS 签的是 CodeDirectory 原字节：签名属性 = contentType / signingTime / messageDigest（CD 的 SHA-256）/ Apple cdhash 两条（plist + SHA-256）；
//   证书带叶证书 + p12 里的链（WWDR 中间证书）。RSA PKCS#1 v1.5 + SHA-256。
// 输入可以已有签名（ad-hoc 或别的证书）：在原 LC_CODE_SIGNATURE 处截断、按新签名大小改该命令与 __LINKEDIT 尺寸后重写，代码页本身不动。
#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "native.h"
#include <sys/stat.h>

#define CS_PAGE_SHIFT 14
#define CS_PAGE (1u << CS_PAGE_SHIFT)

// ---------- 小工具：大端写、可增长缓冲 ----------
typedef struct { uint8_t *p; size_t n, cap; } buf;
static int bput(buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { size_t c = b->cap ? b->cap * 2 : 256; while (c < b->n + n) c *= 2; uint8_t *q = realloc(b->p, c); if (!q) return -1; b->p = q; b->cap = c; }
    if (d) memcpy(b->p + b->n, d, n); else memset(b->p + b->n, 0, n);
    b->n += n; return 0;
}
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void be64(uint8_t *p, uint64_t v) { be32(p, (uint32_t)(v >> 32)); be32(p + 4, (uint32_t)v); }
static uint32_t rd32be(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// ---------- DER ----------
static int der_len(buf *b, size_t n) {
    uint8_t h[5]; int k = 0;
    if (n < 0x80) { h[0] = (uint8_t)n; k = 1; }
    else if (n < 0x100) { h[0] = 0x81; h[1] = (uint8_t)n; k = 2; }
    else if (n < 0x10000) { h[0] = 0x82; h[1] = (uint8_t)(n >> 8); h[2] = (uint8_t)n; k = 3; }
    else { h[0] = 0x83; h[1] = (uint8_t)(n >> 16); h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; k = 4; }
    return bput(b, h, (size_t)k);
}
static int der_tlv(buf *b, uint8_t tag, const void *v, size_t n) { return bput(b, &tag, 1) || der_len(b, n) || bput(b, v, n); }
static int der_wrap(buf *out, uint8_t tag, const buf *in) { return der_tlv(out, tag, in->p, in->n); }
static int der_oid(buf *b, const uint8_t *oid, size_t n) { return der_tlv(b, 0x06, oid, n); }
// 读一个 TLV：返回内容起点与长度，*next = 这个 TLV 之后
static const uint8_t *der_read(const uint8_t *p, const uint8_t *end, uint8_t *tag, size_t *len, const uint8_t **next) {
    if (p + 2 > end) return NULL;
    *tag = p[0]; size_t l = p[1]; const uint8_t *q = p + 2;
    if (l & 0x80) { int k = l & 0x7f; if (k < 1 || k > 3 || q + k > end) return NULL; l = 0; for (int i = 0; i < k; i++) l = l << 8 | q[i]; q += k; }
    if (q + l > end) return NULL;
    *len = l; *next = q + l; return q;
}

static const uint8_t SS_OID_DATA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01};
static const uint8_t SS_OID_SIGNED_DATA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x02};
static const uint8_t SS_OID_SHA256[] = {0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01};
static const uint8_t SS_OID_RSA[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
static const uint8_t SS_OID_CONTENT_TYPE[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x03};
static const uint8_t SS_OID_MESSAGE_DIGEST[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x04};
static const uint8_t SS_OID_SIGNING_TIME[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x05};
static const uint8_t SS_OID_APPLE_CDHASHES[] = {0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,0x09,0x01};    // 1.2.840.113635.100.9.1：cdhash 列表（plist）
static const uint8_t SS_OID_APPLE_CDHASHES2[] = {0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,0x09,0x02};   // 1.2.840.113635.100.9.2：按算法的 cdhash

static int alg_sha256(buf *b) { buf s = {0}; int r = der_oid(&s, SS_OID_SHA256, sizeof SS_OID_SHA256) || der_tlv(&s, 0x05, NULL, 0) || der_wrap(b, 0x30, &s); free(s.p); return r; }

// 叶证书里取 issuer 与 serial 原样 TLV（SignerInfo 的 issuerAndSerialNumber）
static int cert_issuer_serial(const uint8_t *der, size_t n, buf *out) {
    const uint8_t *end = der + n, *nx, *c; uint8_t t; size_t l;
    if (!(c = der_read(der, end, &t, &l, &nx)) || t != 0x30) return -1;            // Certificate
    const uint8_t *tbs = c, *tend; if (!(c = der_read(tbs, c + l, &t, &l, &tend)) || t != 0x30) return -1;   // TBSCertificate
    const uint8_t *p = c, *pend = c + l;
    if (p < pend && *p == 0xa0) { if (!der_read(p, pend, &t, &l, &nx)) return -1; p = nx; }   // [0] version
    const uint8_t *serial = p; if (!der_read(p, pend, &t, &l, &nx) || t != 0x02) return -1; size_t serial_n = (size_t)(nx - serial); p = nx;
    if (!der_read(p, pend, &t, &l, &nx) || t != 0x30) return -1; p = nx;              // signature algorithm
    const uint8_t *issuer = p; if (!der_read(p, pend, &t, &l, &nx) || t != 0x30) return -1; size_t issuer_n = (size_t)(nx - issuer);
    buf s = {0}; int r = bput(&s, issuer, issuer_n) || bput(&s, serial, serial_n) || der_wrap(out, 0x30, &s); free(s.p); return r;
}

// ---------- CodeDirectory ----------
// 返回 CD 字节（cd）；sig_off = 签名在文件里的偏移（= codeLimit），code = 文件前 sig_off 字节
static int build_cd(const uint8_t *code, uint32_t limit, const char *ident, const char *team, const uint8_t req_hash[32], uint64_t exec_base, uint64_t exec_limit, uint64_t exec_flags, buf *cd) {
    uint32_t nslots = (limit + CS_PAGE - 1) >> CS_PAGE_SHIFT, nspecial = 2;
    size_t hdr = 88, ident_n = strlen(ident) + 1, team_n = team ? strlen(team) + 1 : 0;
    size_t ident_off = hdr, team_off = team ? ident_off + ident_n : 0, hash_off = hdr + ident_n + team_n + nspecial * 32;
    size_t total = hash_off + (size_t)nslots * 32;
    if (bput(cd, NULL, total)) return -1;
    uint8_t *h = cd->p;
    be32(h + 0, 0xfade0c02); be32(h + 4, (uint32_t)total); be32(h + 8, 0x20400); be32(h + 12, 0);   // magic / length / version / flags
    be32(h + 16, (uint32_t)hash_off); be32(h + 20, (uint32_t)ident_off); be32(h + 24, nspecial); be32(h + 28, nslots);
    be32(h + 32, limit); h[36] = 32; h[37] = 2; h[38] = 0; h[39] = CS_PAGE_SHIFT; be32(h + 40, 0);   // codeLimit / hashSize / hashType SHA-256 / platform / pageSize / spare2
    be32(h + 44, 0); be32(h + 48, (uint32_t)team_off); be32(h + 52, 0); be64(h + 56, 0);            // scatter / team / spare3 / codeLimit64
    be64(h + 64, exec_base); be64(h + 72, exec_limit); be64(h + 80, exec_flags);
    memcpy(h + ident_off, ident, ident_n);
    if (team) memcpy(h + team_off, team, team_n);
    // 特殊槽从 hash_off 往前：-1 Info.plist（没有，全零）、-2 Requirements
    memcpy(h + hash_off - 2 * 32, req_hash, 32);
    for (uint32_t i = 0; i < nslots; i++) {
        uint32_t off = i << CS_PAGE_SHIFT, len = limit - off < CS_PAGE ? limit - off : CS_PAGE;
        CC_SHA256(code + off, len, h + hash_off + (size_t)i * 32);
    }
    return 0;
}

// ---------- CMS ----------
static int signed_attrs(const uint8_t cd_sha256[32], buf *set_der) {
    buf a = {0}, all = {0}; int r = 0;
    // contentType = id-data
    { buf v = {0}, s = {0}; r |= der_oid(&v, SS_OID_DATA, sizeof SS_OID_DATA) || der_wrap(&s, 0x31, &v); buf at = {0}; r |= der_oid(&at, SS_OID_CONTENT_TYPE, sizeof SS_OID_CONTENT_TYPE) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // signingTime（UTCTime）
    { char ts[16]; time_t now = time(NULL); struct tm g; gmtime_r(&now, &g); strftime(ts, sizeof ts, "%y%m%d%H%M%SZ", &g);
      buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x17, ts, strlen(ts)) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_SIGNING_TIME, sizeof SS_OID_SIGNING_TIME) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // messageDigest = SHA-256(CodeDirectory)
    { buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x04, cd_sha256, 32) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_MESSAGE_DIGEST, sizeof SS_OID_MESSAGE_DIGEST) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(v.p); free(s.p); free(at.p); }
    // Apple cdhashes2：SEQUENCE { sha256 OID, OCTET STRING 整个 cdhash }
    { buf seq = {0}, v = {0}, s = {0}, at = {0}; r |= der_oid(&seq, SS_OID_SHA256, sizeof SS_OID_SHA256) || der_tlv(&seq, 0x04, cd_sha256, 32) || der_wrap(&v, 0x30, &seq) || der_wrap(&s, 0x31, &v)
        || der_oid(&at, SS_OID_APPLE_CDHASHES2, sizeof SS_OID_APPLE_CDHASHES2) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at); free(seq.p); free(v.p); free(s.p); free(at.p); }
    // Apple cdhashes（plist，cdhash 截前 20 字节）
    { static const char head[] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>cdhashes</key>\n\t<array>\n\t\t<data>\n\t\t";
      static const char tail[] = "\n\t\t</data>\n\t</array>\n</dict>\n</plist>\n";
      static const char b64t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      char b64[32]; int k = 0; for (int i = 0; i < 20; i += 3) { uint32_t v = (uint32_t)cd_sha256[i] << 16 | (i + 1 < 20 ? (uint32_t)cd_sha256[i + 1] << 8 : 0) | (i + 2 < 20 ? cd_sha256[i + 2] : 0);
        b64[k++] = b64t[v >> 18 & 63]; b64[k++] = b64t[v >> 12 & 63]; b64[k++] = i + 1 < 20 ? b64t[v >> 6 & 63] : '='; b64[k++] = i + 2 < 20 ? b64t[v & 63] : '='; } b64[k] = 0;
      buf pl = {0}; r |= bput(&pl, head, sizeof head - 1) || bput(&pl, b64, strlen(b64)) || bput(&pl, tail, sizeof tail - 1);
      buf v = {0}, s = {0}, at = {0}; r |= der_tlv(&v, 0x04, pl.p, pl.n) || der_wrap(&s, 0x31, &v) || der_oid(&at, SS_OID_APPLE_CDHASHES, sizeof SS_OID_APPLE_CDHASHES) || bput(&at, s.p, s.n) || der_wrap(&all, 0x30, &at);
      free(pl.p); free(v.p); free(s.p); free(at.p); }
    r |= der_wrap(set_der, 0x31, &all);   // DER SET OF 按编码升序：五条依次 0x30 0x18 / 0x1c / 0x2f / 0x3d / 0x82…（长度字节递增），上面的写入次序就是这个
    free(a.p); free(all.p); return r ? -1 : 0;
}

static int build_cms(const uint8_t cd_sha256[32], SecKeyRef key, CFArrayRef chain, buf *out) {
    CFIndex nc = chain ? CFArrayGetCount(chain) : 0; if (nc < 1) return -1;
    SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
    CFDataRef leaf_der = SecCertificateCopyData(leaf); if (!leaf_der) return -1;
    buf attrs = {0}; if (signed_attrs(cd_sha256, &attrs)) { CFRelease(leaf_der); return -1; }
    CFDataRef tbs = CFDataCreate(NULL, attrs.p, (CFIndex)attrs.n); CFErrorRef err = NULL;
    CFDataRef sig = SecKeyCreateSignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, tbs, &err); CFRelease(tbs);
    if (!sig) { if (err) CFRelease(err); CFRelease(leaf_der); free(attrs.p); return -1; }
    int r = 0;
    // SignerInfo
    buf si = {0}; uint8_t one = 1;
    r |= der_tlv(&si, 0x02, &one, 1);
    r |= cert_issuer_serial(CFDataGetBytePtr(leaf_der), (size_t)CFDataGetLength(leaf_der), &si);
    r |= alg_sha256(&si);
    attrs.p[0] = 0xa0; r |= bput(&si, attrs.p, attrs.n);   // signedAttrs 写成 [0] IMPLICIT（签名时按 SET 0x31 算）
    { buf ra = {0}; r |= der_oid(&ra, SS_OID_RSA, sizeof SS_OID_RSA) || der_tlv(&ra, 0x05, NULL, 0) || der_wrap(&si, 0x30, &ra); free(ra.p); }
    r |= der_tlv(&si, 0x04, CFDataGetBytePtr(sig), (size_t)CFDataGetLength(sig));
    // SignedData
    buf sd = {0}; r |= der_tlv(&sd, 0x02, &one, 1);
    { buf algs = {0}; r |= alg_sha256(&algs) || der_wrap(&sd, 0x31, &algs); free(algs.p); }
    { buf eci = {0}; r |= der_oid(&eci, SS_OID_DATA, sizeof SS_OID_DATA) || der_wrap(&sd, 0x30, &eci); free(eci.p); }
    { buf certs = {0}; for (CFIndex i = 0; i < nc; i++) { CFDataRef d = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(chain, i)); if (!d) { r = -1; continue; } r |= bput(&certs, CFDataGetBytePtr(d), (size_t)CFDataGetLength(d)); CFRelease(d); }
      r |= der_wrap(&sd, 0xa0, &certs); free(certs.p); }
    { buf sis = {0}, w = {0}; r |= der_wrap(&w, 0x30, &si) || bput(&sis, w.p, w.n) || der_wrap(&sd, 0x31, &sis); free(w.p); free(sis.p); }
    // ContentInfo
    buf sdseq = {0}, ex = {0}, ci = {0};
    r |= der_wrap(&sdseq, 0x30, &sd) || der_wrap(&ex, 0xa0, &sdseq) || der_oid(&ci, SS_OID_SIGNED_DATA, sizeof SS_OID_SIGNED_DATA) || bput(&ci, ex.p, ex.n) || der_wrap(out, 0x30, &ci);
    free(si.p); free(sd.p); free(sdseq.p); free(ex.p); free(ci.p); free(attrs.p); CFRelease(sig); CFRelease(leaf_der);
    return r ? -1 : 0;
}

// ---------- Mach-O ----------
// p12 → 私钥 + 证书链；team = 证书 OU（调用方给，或从证书里取）
int s2a_selfsign_identity(const void *p12, size_t n, const char *password, SecKeyRef *key, CFArrayRef *chain) {
    CFDataRef d = CFDataCreate(NULL, p12, (CFIndex)n);
    CFStringRef pw = CFStringCreateWithCString(NULL, password ? password : "", kCFStringEncodingUTF8);
    // 只放进程内存、不进钥匙串（iOS 本来就这样；macOS 不加会写进登录钥匙串、可能弹授权框）
    const void *k[2] = {kSecImportExportPassphrase, NULL}, *v[2] = {pw, kCFBooleanTrue}; CFIndex nk = 1;
    if (__builtin_available(iOS 18.0, macOS 15.0, *)) { k[1] = kSecImportToMemoryOnly; nk = 2; }   // 更老的 iOS 本来就只放内存
    CFDictionaryRef opt = CFDictionaryCreate(NULL, k, v, nk, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef items = NULL; OSStatus st = SecPKCS12Import(d, opt, &items);
    CFRelease(d); CFRelease(pw); CFRelease(opt);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) < 1) { if (items) CFRelease(items); return (int)(st ? st : -1); }
    CFDictionaryRef it = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef id = (SecIdentityRef)CFDictionaryGetValue(it, kSecImportItemIdentity);
    CFArrayRef ch = CFDictionaryGetValue(it, kSecImportItemCertChain);
    if (!id || SecIdentityCopyPrivateKey(id, key) != errSecSuccess) { CFRelease(items); return -2; }
    if (ch && CFArrayGetCount(ch) > 0) *chain = CFRetain(ch);
    else { SecCertificateRef c = NULL; SecIdentityCopyCertificate(id, &c); const void *cv[] = {c}; *chain = CFArrayCreate(NULL, cv, 1, &kCFTypeArrayCallBacks); if (c) CFRelease(c); }
    CFRelease(items); return 0;
}

// 给 in（整份文件，arm64 单架构 dylib / 可执行）签名，结果写 out（调用方 free）。ident = 签名标识（NULL = 沿用原签名里的），team = 团队号
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n) {
#define FAIL(...) do { snprintf(why, why_n, __VA_ARGS__); free(cd.p); free(cms.p); free(req.p); free(sb.p); free(o.p); return -1; } while (0)
    buf cd = {0}, cms = {0}, req = {0}, sb = {0}, o = {0};
    if (n < sizeof(struct mach_header_64)) FAIL("文件太小");
    const struct mach_header_64 *mh = (const void *)in;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) FAIL("不是 arm64 单架构 Mach-O（magic %#x）", mh->magic);
    const uint8_t *lc = in + sizeof *mh; struct linkedit_data_command *sig = NULL; struct segment_command_64 *le = NULL; uint64_t text_off = 0, text_size = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *c = (const void *)lc;
        if (c->cmd == LC_CODE_SIGNATURE) sig = (void *)c;
        if (c->cmd == LC_SEGMENT_64) { struct segment_command_64 *s = (void *)c; if (!strcmp(s->segname, "__LINKEDIT")) le = s; if (!strcmp(s->segname, "__TEXT")) { text_off = s->fileoff; text_size = s->filesize; } }
        lc += c->cmdsize;
    }
    if (!sig || !le) FAIL("没有 LC_CODE_SIGNATURE / __LINKEDIT（要先有一份签名，ad-hoc 也行）");
    uint32_t limit = sig->dataoff;
    if (limit > n || le->fileoff > limit) FAIL("签名偏移越界");
    // 沿用原标识
    char ident_buf[512] = {0};
    if (!ident) {
        const uint8_t *sbp = in + sig->dataoff; uint32_t cnt = sig->datasize >= 12 ? rd32be(sbp + 8) : 0;
        for (uint32_t i = 0; i < cnt && 12 + i * 8 + 8 <= sig->datasize; i++) {
            uint32_t type = rd32be(sbp + 12 + i * 8), off = rd32be(sbp + 16 + i * 8);
            if (type == 0 && off + 24 <= sig->datasize && rd32be(sbp + off) == 0xfade0c02) { uint32_t io = rd32be(sbp + off + 20); snprintf(ident_buf, sizeof ident_buf, "%s", (const char *)sbp + off + io); break; }
        }
        if (!ident_buf[0]) FAIL("原签名里找不到标识");
        ident = ident_buf;
    }
    // 空 Requirements 集合：magic 0xfade0c01 / 长度 12 / 个数 0
    uint8_t rq[12]; be32(rq, 0xfade0c01); be32(rq + 4, 12); be32(rq + 8, 0); bput(&req, rq, 12);
    uint8_t req_hash[32]; CC_SHA256(rq, 12, req_hash);
    // 先算一次签名大小，改头再出 CD（CD 覆盖到 codeLimit，含已改过的头）
    uint8_t *code = malloc(limit); if (!code) FAIL("内存不足"); memcpy(code, in, limit);
    uint32_t est = 0;
    for (int pass = 0; pass < 2; pass++) {
        free(cd.p); cd = (buf){0}; free(cms.p); cms = (buf){0};
        if (pass == 1) {   // 按估好的大小改 LC_CODE_SIGNATURE 与 __LINKEDIT
            struct linkedit_data_command *s2 = (void *)(code + ((const uint8_t *)sig - in));
            struct segment_command_64 *l2 = (void *)(code + ((const uint8_t *)le - in));
            s2->datasize = est; l2->filesize = (uint64_t)limit + est - l2->fileoff;
            l2->vmsize = (l2->filesize + CS_PAGE - 1) & ~(uint64_t)(CS_PAGE - 1);
        }
        if (build_cd(code, limit, ident, team, req_hash, text_off, text_size, mh->filetype == MH_EXECUTE ? 1 : 0, &cd)) { free(code); FAIL("出 CodeDirectory 失败"); }
        uint8_t h[32]; CC_SHA256(cd.p, (CC_LONG)cd.n, h);
        if (build_cms(h, key, chain, &cms)) { free(code); FAIL("出 CMS 签名失败（私钥签不了或证书解析失败）"); }
        uint32_t need = (uint32_t)(12 + 3 * 8 + cd.n + req.n + cms.n);
        if (pass == 0) est = (need + 1024 + 15) & ~15u;   // 留 1 KiB 余量（第二遍签名时间长度不变，CMS 长度只差几个字节）
        else if (need > est) { free(code); FAIL("签名比预留大（%u > %u）", need, est); }
    }
    // SuperBlob：CodeDirectory(0) / Requirements(2) / CMS(0x10000)
    uint32_t off0 = 12 + 3 * 8, off1 = off0 + (uint32_t)cd.n, off2 = off1 + (uint32_t)req.n;
    bput(&sb, NULL, off0); be32(sb.p, 0xfade0cc0); be32(sb.p + 4, off2 + (uint32_t)cms.n + 8); be32(sb.p + 8, 3);
    be32(sb.p + 12, 0); be32(sb.p + 16, off0); be32(sb.p + 20, 2); be32(sb.p + 24, off1); be32(sb.p + 28, 0x10000); be32(sb.p + 32, off2);
    bput(&sb, cd.p, cd.n); bput(&sb, req.p, req.n);
    { uint8_t wh[8]; be32(wh, 0xfade0b01); be32(wh + 4, (uint32_t)cms.n + 8); bput(&sb, wh, 8); bput(&sb, cms.p, cms.n); }   // CMS 包成 BlobWrapper
    if (sb.n > est) { free(code); FAIL("SuperBlob 比预留大"); }
    be32(sb.p + 4, (uint32_t)sb.n);
    bput(&o, code, limit); bput(&o, sb.p, sb.n); bput(&o, NULL, est - sb.n);
    free(code); free(cd.p); free(cms.p); free(req.p); free(sb.p);
    *out = o.p; *out_n = o.n; return 0;
#undef FAIL
}

// ---------- 真机验证入口（0.6.0 可行性，开发用环境变量；玩家路径不设就不走）----------
// S2A_SELFSIGN_P12 / S2A_SELFSIGN_IN / S2A_SELFSIGN_OUT（@home/ 前缀 = App 数据容器）、S2A_SELFSIGN_PW、S2A_SELFSIGN_TEAM：
//   起局构造期（launchctx.c 定启动上下文之前）在手机上把 IN 用 p12 重签写到 OUT，日志记耗时与大小；之后照常按启动上下文加载 OUT
static int home_path(char *out, size_t n, const char *p) {
    if (!strncmp(p, "@home/", 6)) { const char *h = getenv("HOME"); if (!h) return -1; snprintf(out, n, "%s/%s", h, p + 6); } else snprintf(out, n, "%s", p);
    return 0;
}
static uint8_t *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = l > 0 ? malloc((size_t)l) : NULL; if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f); *n = (size_t)l; return b;
}
void s2a_selfsign_probe(void) {
    const char *p12 = getenv("S2A_SELFSIGN_P12"), *in = getenv("S2A_SELFSIGN_IN"), *out = getenv("S2A_SELFSIGN_OUT");
    if (!p12 || !in || !out) return;
    char pp[1024], pi[1024], po[1024], why[256] = {0};
    if (home_path(pp, sizeof pp, p12) || home_path(pi, sizeof pi, in) || home_path(po, sizeof po, out)) { LOG("【红】手机端自签：路径展不开"); return; }
    struct timespec t0, t1, t2; clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t pn = 0, n = 0; uint8_t *pb = slurp(pp, &pn), *ib = slurp(pi, &n);
    if (!pb || !ib) { LOG("【红】手机端自签：读不到 %s", !pb ? pp : pi); free(pb); free(ib); return; }
    SecKeyRef key = NULL; CFArrayRef chain = NULL;
    int rc = s2a_selfsign_identity(pb, pn, getenv("S2A_SELFSIGN_PW"), &key, &chain); free(pb);
    if (rc) { LOG("【红】手机端自签：p12 导入失败（%d）", rc); free(ib); return; }
    // iOS 的 SecPKCS12Import 只给 p12 里的证书（玩家导出的 p12 通常只有叶证书），macOS 会从系统补齐链。
    //   签名里缺 WWDR 中间证书，内核注册签名就验不过链（真机 errno=1）。S2A_SELFSIGN_CHAIN = 冒号分隔的 DER 证书（中间证书、根证书），叶证书之后接上。
    //   做成产品时这几张苹果公开证书随 App 带，按叶证书的签发者挑 WWDR 那一代
    const char *ce = getenv("S2A_SELFSIGN_CHAIN");
    if (ce && *ce && CFArrayGetCount(chain) == 1) {
        CFMutableArrayRef full = CFArrayCreateMutableCopy(NULL, 0, chain); char list[4096]; snprintf(list, sizeof list, "%s", ce);
        for (char *sv = NULL, *tok = strtok_r(list, ":", &sv); tok; tok = strtok_r(NULL, ":", &sv)) {
            char cp[1024]; size_t cn = 0; uint8_t *cb = home_path(cp, sizeof cp, tok) ? NULL : slurp(cp, &cn);
            CFDataRef cd = cb ? CFDataCreate(NULL, cb, (CFIndex)cn) : NULL; free(cb);
            SecCertificateRef c = cd ? SecCertificateCreateWithData(NULL, cd) : NULL; if (cd) CFRelease(cd);
            if (c) { CFArrayAppendValue(full, c); CFRelease(c); } else LOG("【黄】手机端自签：链证书读不了 %s", tok);
        }
        CFRelease(chain); chain = full;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    uint8_t *ob = NULL; size_t on = 0;
    rc = s2a_selfsign_macho(ib, n, NULL, getenv("S2A_SELFSIGN_TEAM"), key, chain, &ob, &on, why, sizeof why);
    clock_gettime(CLOCK_MONOTONIC, &t2);
    long nchain = (long)CFArrayGetCount(chain); free(ib); CFRelease(key); CFRelease(chain);
    if (rc) { LOG("【红】手机端自签：签名失败：%s", why); return; }
    for (char *q = po + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(po, 0755); *q = '/'; }   // 上级目录可能还没建（program/）
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", po);
    FILE *f = fopen(tmp, "wb"); int ok = f && fwrite(ob, 1, on, f) == on; if (f && fclose(f)) ok = 0; free(ob);
    if (!ok || rename(tmp, po)) { LOG("【红】手机端自签：写不进 %s", po); return; }
    LOG("手机端自签：在本机用 p12（证书链 %ld 张）重签 %s → %s，%zu → %zu 字节；导入证书 %.0f ms、签名 %.0f ms",
        nchain, pi, po, n, on, (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, (t2.tv_sec - t1.tv_sec) * 1e3 + (t2.tv_nsec - t1.tv_nsec) / 1e6);
}
