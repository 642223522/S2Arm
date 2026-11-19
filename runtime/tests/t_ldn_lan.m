// 苹果局域网联机（ios/ldn_lan.m）的「是不是本机」与「选谁当中继」必须走与安卓共用的那份实现
//   （runtime/src/lan_elect.c，规则本身由 t_lan_elect 测）。审计 P2-12：原先 ldn_lan.m 用 NSString 自写一份，生产从不调可测的那份，
//   两边规则一漂移，同一 Wi-Fi 的苹果机和安卓机就选出不同的中继。
// 这里把被测文件整份编进来，换上「故意和名字最小规则不同」的假 s2a_lan_elect / s2a_lan_is_self：生产代码照假实现的答案走 = 确实委托给共用实现；
//   自写比较的旧代码不理假实现，照「名字最小」选 → 红。不碰网络：不调 start（不发布、不浏览、不解析），只直接驱动 elect / isSelf。
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

#include "../../ios/ldn_lan.m"

static int failures;
static void check(int ok, const char *what) {
    if (!ok) { failures++; fprintf(stderr, "✗ t_ldn_lan: %s\n", what); }
}

// 被测文件引用的外部符号：权限说明（lan_permission.m）与共享层的改指入口
void s2a_lan_permission_then(int dev_mode, void (^go)(void)) { (void)dev_mode; (void)go; }
static int g_perm_failed;
void s2a_lan_permission_failed(const char *what, NSDictionary *err) { (void)what; (void)err; g_perm_failed++; }
static char g_server[64];
static int g_set_calls;
void S2A_LdnSetServer(const char *ipv4) { snprintf(g_server, sizeof g_server, "%s", ipv4); g_set_calls++; }

// 假共用实现：选名字「最大」的那个（与真规则相反）；记下收到的前缀与候选
static int g_elect_calls, g_elect_n, g_own_seen;
static char g_elect_prefix[64];
int s2a_lan_elect(const char *prefix, const char *const *names, int n) {
    g_elect_calls++; g_elect_n = n; g_own_seen = 0;
    snprintf(g_elect_prefix, sizeof g_elect_prefix, "%s", prefix ? prefix : "");
    int best = -1;
    for (int i = 0; i < n; i++) {
        if (!strcmp(names[i], "0100000000000001-bbbb")) g_own_seen = 1;
        if (best < 0 || strcmp(names[i], names[best]) > 0) best = i;
    }
    return best;
}
// 假共用实现：只认「zzzz」是本机（真规则下 bbbb 才是）
static int g_self_calls;
int s2a_lan_is_self(const char *prefix, const char *dev, const char *name) {
    (void)prefix; (void)dev;
    g_self_calls++;
    return strstr(name, "zzzz") != NULL;
}

// 前后台用：重开 Bonjour 只计数（不碰网络）
@interface TLan : S2ALdnLan
@property int restarts;
@end
@implementation TLan
- (void)restartBonjour { self.restarts++; }
@end
static void post(NSString *name) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];   // 观察者挂在主队列上
}

int main(void) {
    @autoreleasepool {
        S2ALdnLan *lan = [S2ALdnLan new];
        lan.prefix = @"0100000000000001-"; lan.dev = @"bbbb"; lan.ownName = @"0100000000000001-bbbb";
        lan.ips = [@{@"0100000000000001-aaaa": @"10.0.0.1", @"0100000000000001-cccc": @"10.0.0.3"} mutableCopy];
        pthread_mutex_lock(&g_lan_gate); g_lan = lan; pthread_mutex_unlock(&g_lan_gate);

        // 1. 选举委托：假实现选最大的 cccc → 改指 10.0.0.3（自写「名字最小」会选 aaaa → 10.0.0.1）
        [lan elect];
        check(g_elect_calls == 1, "elect 没调 s2a_lan_elect（生产仍自写比较）");
        check(g_set_calls == 1 && !strcmp(g_server, "10.0.0.3"), "选中中继没按共用实现的答案（应 10.0.0.3）");
        // 候选 = 本机 + 已解析的两台，前缀原样递过去（共用实现要求调用方把本机名放进候选）
        check(g_elect_n == 3 && g_own_seen && !strcmp(g_elect_prefix, "0100000000000001-"), "递给 s2a_lan_elect 的候选 / 前缀不对（应本机 + 2 台、前缀 <程序号>-）");

        // 2. 共用实现选中本机 → 回环地址
        [lan.ips removeObjectForKey:@"0100000000000001-cccc"];
        lan.ips[@"0100000000000001-0000"] = @"10.0.0.9";   // 比本机小：真规则会选它，假实现选最大 = 本机 bbbb
        [lan elect];
        check(!strcmp(g_server, "127.0.0.1"), "共用实现选中本机时没改指回环 127.0.0.1");

        // 3. 是不是本机委托：假实现只认 zzzz（自写判定认 bbbb / !bbbb）
        check([lan isSelf:@"0100000000000001-zzzz"] && ![lan isSelf:@"0100000000000001-!bbbb"] && g_self_calls == 2,
              "isSelf 没走 s2a_lan_is_self（生产仍自写判定）");

        pthread_mutex_lock(&g_lan_gate); g_lan = nil; pthread_mutex_unlock(&g_lan_gate);

        // 4. 进后台：系统停掉 Bonjour，两个失败回调回 -72000→ 不当「权限被拒」弹框；回前台 → 重开一次。前台的失败照旧引导去设置
        TLan *t = [TLan new];
        t.prefix = @"0100000000000001-"; t.dev = @"bbbb"; t.ownName = @"0100000000000001-bbbb";
        t.own = [[NSNetService alloc] initWithDomain:@"local." type:@"_s2arm-ldn._tcp." name:t.ownName port:1]; t.browser = [NSNetServiceBrowser new];
        pthread_mutex_lock(&g_lan_gate); g_lan = t; pthread_mutex_unlock(&g_lan_gate);
        [t watchLife];
        NSDictionary *e72000 = @{NSNetServicesErrorCode: @(-72000), NSNetServicesErrorDomain: @10};
        post(@"UIApplicationDidEnterBackgroundNotification");
        [t netServiceBrowser:t.browser didNotSearch:e72000]; [t netService:t.own didNotPublish:e72000];
        check(g_perm_failed == 0, "进后台时 Bonjour 被系统停掉（-72000）却当成本地网络权限被拒（应只记日志）");
        check(t.restarts == 0, "还在后台就重开了 Bonjour");
        post(@"UIApplicationWillEnterForegroundNotification");
        check(t.restarts == 1, "回前台没重新发布 / 查找（之后一直找不到别的设备）");
        post(@"UIApplicationWillEnterForegroundNotification");
        check(t.restarts == 1, "没进过后台的回前台通知也重开了");
        [t netServiceBrowser:t.browser didNotSearch:e72000];
        check(g_perm_failed == 1, "前台的浏览失败没交给权限引导");
        [t netServiceBrowser:[NSNetServiceBrowser new] didNotSearch:e72000];
        check(g_perm_failed == 1, "已换掉的旧浏览器的失败也弹了引导");
        [t stop];
        post(@"UIApplicationDidEnterBackgroundNotification"); post(@"UIApplicationWillEnterForegroundNotification");
        check(t.restarts == 1, "停掉之后前后台通知还在重开");
        pthread_mutex_lock(&g_lan_gate); g_lan = nil; pthread_mutex_unlock(&g_lan_gate);
    }
    if (failures) return 1;
    puts("✓ t_ldn_lan: 苹果联机的选举 / 本机判定委托共用 s2a_lan_elect / s2a_lan_is_self，选中本机走回环；进后台的 Bonjour 失败不当权限被拒、回前台重开");
    return 0;
}
