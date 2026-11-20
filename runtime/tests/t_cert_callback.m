// ios/cert_callback.m 单测（Mac，只用 Foundation）：SideStore「导出证书」往返地址。期望值不靠被测实现：证书字节是单测自己写的，
//   回调地址照 SideStore ExportCertificateDialog 的做法拼（base64 后编码掉 ;/?:@&=+$, 和空格、密码原样）。
//   ① 请求地址：sidestore://certificate?callback_template=…，取值解码后正是 s2arm://sidestore-cert?cert=$(BASE64_CERT)&pw=$(PASSWORD)
//   ② SideStore 编码过的证书 + 带 & 的密码 → 字节一致、密码整段；③ 没编码的 base64、URL 安全字母表、缺填充 → 字节一致
//   ④ 没换占位 / 空证书 → -2；别的地址（小组件 s2arm://play/…）→ -1
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "s2a_t_result.h"
NSURL *s2a_cert_sidestore_request(void);
int s2a_cert_callback_parse(NSString *url, NSData **p12, NSString **pw);
static int bad;
static void ck(int ok, NSString *what) { printf("%s %s\n", ok ? "  通" : "  【红】", what.UTF8String); if (!ok) bad++; }
int main(void) { @autoreleasepool {
    NSURLComponents *rq = [NSURLComponents componentsWithURL:s2a_cert_sidestore_request() resolvingAgainstBaseURL:NO];
    NSString *tpl = nil; for (NSURLQueryItem *i in rq.queryItems) if ([i.name isEqualToString:@"callback_template"]) tpl = i.value;
    ck([rq.scheme isEqualToString:@"sidestore"] && [rq.host isEqualToString:@"certificate"] && [tpl isEqualToString:@"s2arm://sidestore-cert?cert=$(BASE64_CERT)&pw=$(PASSWORD)"],
       [NSString stringWithFormat:@"① 请求地址 %@，回调模板 %@", rq.URL.absoluteString, tpl]);
    uint8_t raw[300]; for (int i = 0; i < 300; i++) raw[i] = (uint8_t)(i * 37 + 11);   // 含 +、/、= 的 base64
    NSData *want = [NSData dataWithBytes:raw length:sizeof raw]; NSString *b64 = [want base64EncodedStringWithOptions:0];
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy]; [allowed removeCharactersInString:@";/?:@&=+$, "];
    NSString *ss = [b64 stringByAddingPercentEncodingWithAllowedCharacters:allowed];   // 同 SideStore activeSigningCertificateBase64Encoded
    NSString *u = [[tpl stringByReplacingOccurrencesOfString:@"$(BASE64_CERT)" withString:ss] stringByReplacingOccurrencesOfString:@"$(PASSWORD)" withString:@"a&b=c"];
    NSData *got = nil; NSString *pw = nil; int r = s2a_cert_callback_parse(u, &got, &pw);
    ck(r == 0 && [got isEqualToData:want] && [pw isEqualToString:@"a&b=c"], [NSString stringWithFormat:@"② SideStore 编码的证书 + 带 & 的密码：返回 %d、字节%@、密码「%@」", r, [got isEqualToData:want] ? @"一致" : @"不一致", pw]);
    r = s2a_cert_callback_parse([@"s2arm://sidestore-cert?cert=" stringByAppendingString:b64], &got, &pw);
    ck(r == 0 && [got isEqualToData:want] && [pw isEqualToString:@""], [NSString stringWithFormat:@"③ 没编码的 base64、没有密码段：返回 %d、字节%@", r, [got isEqualToData:want] ? @"一致" : @"不一致"]);
    NSString *urlsafe = [[[b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
    r = s2a_cert_callback_parse([NSString stringWithFormat:@"S2ARM://sidestore-cert?cert=%@&pw=", urlsafe], &got, &pw);
    ck(r == 0 && [got isEqualToData:want], [NSString stringWithFormat:@"③ URL 安全字母表、去掉填充、大写方案：返回 %d、字节%@", r, [got isEqualToData:want] ? @"一致" : @"不一致"]);
    ck(s2a_cert_callback_parse(tpl, &got, &pw) == -2, @"④ 没换占位（原样模板）→ -2");
    ck(s2a_cert_callback_parse(@"s2arm://sidestore-cert?cert=&pw=x", &got, &pw) == -2, @"④ 空证书 → -2");
    ck(s2a_cert_callback_parse(@"s2arm://play/0100ABCDE0000000", &got, &pw) == -1, @"④ 小组件地址 → -1（不是这个回调）");
    return S2A_T_RESULT("t_cert_callback", bad);
} }
