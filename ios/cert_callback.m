// SideStore「把签名证书交给别的 App」的往返地址（0.6.0：SideStore 装的玩家不经电脑拿到签名证书；只用 Foundation，单测 runtime/tests/t_cert_callback.m 在 Mac 上跑）。
// 协议（SideStore develop 分支 DeepLinks/URLHandler.swift、ExportCertificateDialog.swift）：别的 App 打开 sidestore://certificate?callback_template=<回调模板>，
//   SideStore 问玩家，点 Export 后把模板里的 $(BASE64_CERT) 换成当前签名证书（.p12 的 base64，再百分号编码掉 ;/?:@&=+$, 和空格）、$(PASSWORD) 换成密码（原样，不编码），
//   打开得到的地址。我们的模板把证书放前、密码放最后：s2arm://sidestore-cert?cert=$(BASE64_CERT)&pw=$(PASSWORD)——证书段里不会有 &（已编码），
//   密码段取 &pw= 之后的全部（密码里有 & 也不切错）。SideStore 给的 .p12 是不带 MAC 的明文格式、密码不起作用（selfsign.c p12_plain）
#import <Foundation/Foundation.h>

static NSString *const kTemplate = @"s2arm://sidestore-cert?cert=$(BASE64_CERT)&pw=$(PASSWORD)";

NSURL *s2a_cert_sidestore_request(void) {
    NSMutableCharacterSet *ok = [NSCharacterSet.alphanumericCharacterSet mutableCopy]; [ok addCharactersInString:@"-._~"];   // 回调模板整段编码进一个查询值（SideStore 取值后 removingPercentEncoding）
    NSString *enc = [kTemplate stringByAddingPercentEncodingWithAllowedCharacters:ok];
    return [NSURL URLWithString:[@"sidestore://certificate?callback_template=" stringByAppendingString:enc]];
}
// 0 = 取到（p12 / pw 带回，pw 可能是空串）；-1 = 不是这个回调；-2 = 是这个回调但没有能解出的证书
int s2a_cert_callback_parse(NSString *url, NSData **p12, NSString **pw) {
    if (p12) *p12 = nil; if (pw) *pw = nil;
    NSRange head = [url rangeOfString:@"s2arm://sidestore-cert?" options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (head.location == NSNotFound) return -1;
    NSString *q = [url substringFromIndex:NSMaxRange(head)];
    if (![q hasPrefix:@"cert="]) return -2;
    NSRange amp = [q rangeOfString:@"&pw="];
    NSString *c = amp.location == NSNotFound ? [q substringFromIndex:5] : [q substringWithRange:NSMakeRange(5, amp.location - 5)];
    NSString *p = amp.location == NSNotFound ? @"" : [q substringFromIndex:NSMaxRange(amp)];
    NSString *dec = c.stringByRemovingPercentEncoding ?: c;
    // base64：兼容 URL 安全字母表、中途被当成空格的 +、缺的填充
    NSMutableString *b = [[[dec stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    [b replaceOccurrencesOfString:@" " withString:@"+" options:0 range:NSMakeRange(0, b.length)];
    while (b.length % 4) [b appendString:@"="];
    NSData *d = b.length ? [[NSData alloc] initWithBase64EncodedString:b options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
    if (!d.length || [dec containsString:@"$(BASE64_CERT)"]) return -2;   // SideStore 没换占位（版本不认这个接口）
    if (p12) *p12 = d;
    if (pw) *pw = [p isEqualToString:@"$(PASSWORD)"] ? @"" : p;
    return 0;
}
