// 金手指面板（11-09 B 方案）：齿轮菜单进入。只管文件：导入 txt 到 <文档根>/cheats/、开关写 enabled.txt（每行「文件名/条目名」，缺省全关）、
//   读服务层写的 status.txt 显示每条状态（每秒刷新）。执行、版本校验、改代码拦截都在 services/S2A.Services/Cheats.cs，开关约 1 秒内生效，不用重启。
//   解析规则与 Cheats.cs Parse 一致：[名字] 普通条目，{名字} 主代码（不单独列开关，随同文件任一条开着执行），其余非空行是指令。
#import "vpad_cheats.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "s2a_docs.h"

// 弱链接[lab]：s2a_main_build_id（runtime/src/loader.c 主程序构建号；输入工作台不链原生核，取不到就不显示版本号提示）
const char *s2a_main_build_id(void) __attribute__((weak_import));

NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text) {
    NSMutableArray *out = [NSMutableArray array]; NSString *cur = nil; BOOL master = NO; NSInteger lines = 0;
    void (^flush)(void) = ^{ if (lines > 0) [out addObject:@{@"name": cur ?: @"未命名", @"master": @(master)}]; };
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!l.length) continue;
        unichar c = [l characterAtIndex:0];
        if (c == '[' || c == '{') {
            unichar close = c == '[' ? ']' : '}';
            if (l.length < 2 || [l characterAtIndex:l.length - 1] != close) return nil;
            flush(); lines = 0; master = c == '{';
            cur = [[l substringWithRange:NSMakeRange(1, l.length - 2)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!cur.length) cur = master ? @"主代码" : @"未命名";
        } else lines++;
    }
    flush();
    return out;
}

static NSURL *cheats_dir(void) {   // 文档根唯一取法（s2a_docs.h），与服务层 Cheats.cs 同一目录
    char d[1024]; s2a_docs_path(d, sizeof d, "cheats");
    return [NSURL fileURLWithPath:@(d) isDirectory:YES];
}

@interface S2ACheatFile : NSObject
@property (nonatomic, copy) NSString *file; @property (nonatomic, copy) NSArray<NSString *> *names; @property (nonatomic) BOOL bad;
@end
@implementation S2ACheatFile
@end

@interface S2ACheatsPanel : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^closed)(void);
@end
@implementation S2ACheatsPanel {
    NSArray<S2ACheatFile *> *_files; NSMutableSet<NSString *> *_on; NSDictionary<NSString *, NSString *> *_status; NSTimer *_timer;
}
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"金手指"; return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导入 txt" style:UIBarButtonItemStylePlain target:self action:@selector(import)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"cheats.import";
    [self reload];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; __weak typeof(self) ws = self; _timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { (void)t; [ws refreshStatus]; }]; }
- (void)viewDidDisappear:(BOOL)a { [super viewDidDisappear:a]; [_timer invalidate]; _timer = nil; if (self.isBeingDismissed || self.navigationController.isBeingDismissed) { if (_closed) _closed(); _closed = nil; } }
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager; NSURL *dir = cheats_dir();
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:dir.path error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f.pathExtension.lowercaseString isEqual:@"txt"] || [f isEqual:@"enabled.txt"] || [f isEqual:@"status.txt"]) continue;
        NSString *text = [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        NSArray *parsed = text ? s2a_cheats_parse(text) : nil;
        S2ACheatFile *cf = [S2ACheatFile new]; cf.file = f; cf.bad = parsed == nil;
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *e in parsed) if (![e[@"master"] boolValue]) [names addObject:e[@"name"]];
        cf.names = names; [files addObject:cf];
    }
    _files = files;
    NSString *en = [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:@"enabled.txt"] encoding:NSUTF8StringEncoding error:nil];
    _on = [NSMutableSet setWithArray:[en componentsSeparatedByString:@"\n"] ?: @[]]; [_on removeObject:@""];
    [self readStatus]; [self.tableView reloadData];
}
- (void)readStatus {
    NSString *st = [NSString stringWithContentsOfURL:[cheats_dir() URLByAppendingPathComponent:@"status.txt"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *l in [st componentsSeparatedByString:@"\n"]) { NSArray *p = [l componentsSeparatedByString:@"\t"]; if (p.count == 2) m[p[0]] = p[1]; }
    _status = m;
}
- (void)refreshStatus {
    NSDictionary *old = _status; [self readStatus];
    if (![old isEqualToDictionary:_status]) [self.tableView reloadData];
}
- (BOOL)writeEnabled {
    NSURL *dir = cheats_dir(); NSError *e;
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *body = [[[_on allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    if ([[body stringByAppendingString:@"\n"] writeToURL:[dir URLByAppendingPathComponent:@"enabled.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&e]) return YES;
    [self alert:@"开关没保存" message:e.localizedDescription]; return NO;
}
- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}

- (void)import {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePlainText, UTTypeText] asCopy:YES];
    p.allowsMultipleSelection = YES; p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)c; NSFileManager *fm = NSFileManager.defaultManager; NSURL *dir = cheats_dir(); NSMutableArray *bad = [NSMutableArray array];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *u in urls) {
        NSString *text = [NSString stringWithContentsOfURL:u encoding:NSUTF8StringEncoding error:nil];
        NSString *name = u.lastPathComponent;
        if (![name.pathExtension.lowercaseString isEqual:@"txt"]) name = [name stringByAppendingPathExtension:@"txt"];
        if (!text || !s2a_cheats_parse(text).count || [name isEqual:@"enabled.txt"] || [name isEqual:@"status.txt"]) { [bad addObject:u.lastPathComponent]; continue; }
        NSURL *dst = [dir URLByAppendingPathComponent:name]; NSError *e;
        if (![text writeToURL:dst atomically:YES encoding:NSUTF8StringEncoding error:&e]) [bad addObject:[NSString stringWithFormat:@"%@（%@）", u.lastPathComponent, e.localizedDescription]];
    }
    [self reload];
    if (bad.count) [self alert:@"有文件没导入" message:[NSString stringWithFormat:@"%@\n\n不是 Atmosphere 格式的金手指文本（要有 [条目名] 和指令行）。", [bad componentsJoinedByString:@"\n"]]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { (void)t; return 1 + (NSInteger)_files.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t; if (s == 0) return 0;
    S2ACheatFile *f = _files[s - 1]; return (f.bad ? 0 : (NSInteger)f.names.count) + 1;   // 末行「删除这份文件」
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    (void)t; if (s == 0) return nil;
    S2ACheatFile *f = _files[s - 1]; NSString *st = _status[[f.file stringByAppendingString:@"/*"]];
    if (f.bad) return [f.file stringByAppendingString:@" · 格式不对"];
    for (NSString *n in f.names) if ([_status[[NSString stringWithFormat:@"%@/%@", f.file, n]] isEqual:@"版本不符"]) st = @"版本不符，不会生效";
    return st ? [NSString stringWithFormat:@"%@ · %@", f.file, st] : f.file;
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    (void)t; if (s != 0) return nil;
    const char *b = s2a_main_build_id ? s2a_main_build_id() : NULL;
    NSString *bid = b && strlen(b) >= 16 ? [@(b) substringToIndex:16].uppercaseString : nil;
    NSMutableString *m = [NSMutableString stringWithString:@"导入 Atmosphere 格式的金手指（txt）。每条缺省关，打开后约 1 秒内生效，不用重启；"
                          "要改游戏代码的条目在本机不支持，会自动停用。金手指可能让存档出问题，请先备份存档。"];
    if (bid) [m appendFormat:@"\n\n本游戏版本号（构建号前 16 位）：%@。金手指文件名通常就是它，名字对不上的文件不会生效。", bid];
    if (!_files.count) [m appendString:@"\n\n还没有金手指文件，点右上角「导入 txt」。"];
    return m;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    (void)t; S2ACheatFile *f = _files[ip.section - 1];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.row >= (NSInteger)(f.bad ? 0 : f.names.count)) {
        cell.textLabel.text = @"删除这份文件"; cell.textLabel.textColor = UIColor.systemRedColor; return cell;
    }
    NSString *name = f.names[ip.row], *key = [NSString stringWithFormat:@"%@/%@", f.file, name];
    cell.textLabel.text = name; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    BOOL on = [_on containsObject:key]; NSString *st = _status[key];
    cell.detailTextLabel.text = on ? (st && ![st isEqual:@"关"] ? st : @"等待生效…") : nil;
    cell.detailTextLabel.textColor = [st isEqual:@"生效中"] ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    UISwitch *sw = [UISwitch new]; sw.on = on; sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
    return cell;
}
- (void)toggled:(UISwitch *)sw {
    NSString *key = sw.accessibilityIdentifier;
    if (sw.on) [_on addObject:key]; else [_on removeObject:key];
    if (![self writeEnabled]) { sw.on = !sw.on; if (sw.on) [_on addObject:key]; else [_on removeObject:key]; }
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    S2ACheatFile *f = _files[ip.section - 1];
    if (ip.row < (NSInteger)(f.bad ? 0 : f.names.count)) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除「%@」？", f.file] message:@"这份文件里开着的条目会一起停用。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x;
        NSError *e;
        if (![NSFileManager.defaultManager removeItemAtURL:[cheats_dir() URLByAppendingPathComponent:f.file] error:&e]) { [self alert:@"没删掉" message:e.localizedDescription]; return; }
        NSString *prefix = [f.file stringByAppendingString:@"/"];
        for (NSString *k in [_on allObjects]) if ([k hasPrefix:prefix]) [_on removeObject:k];
        [self writeEnabled]; [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

void s2a_cheats_present(UIViewController *host, void (^closed)(void)) {
    S2ACheatsPanel *p = [S2ACheatsPanel new]; p.closed = closed;
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:p];
    [host presentViewController:n animated:YES completion:nil];
}
