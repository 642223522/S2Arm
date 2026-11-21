// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘改键页（#1869）：交互同 Mac 启动器改键（launchers/macos/frontend/Sources/NX2Apple/InputSettingsSheet.swift）——
//   点一个按键位后按键盘上的新键录入，Esc 取消；另有「常用键」（Return、Esc、空格、Tab、Shift、Ctrl、Option，同 Mac commonKeys）与「清除键盘按键」；
//   要绑的键已给了别的按键位时先问「改绑这个键？」，确认就解开旧的再绑（存下来的键位没有重复绑定，共用解析器拒收重复）。
//   iPad 在游戏里改：改完当场生效（Mac 在启动器里改、下次起局生效），按款存 schema 1 JSON（同 Mac input.json）。
//   只改键盘部分；鼠标 / 触控板随后续 PR。页面开着时键盘不进游戏（keyboard.m 静音）。入口：齿轮菜单第一层，「编辑虚拟按键」旁（vpad.m）
#import <UIKit/UIKit.h>
#import "s2a_l10n.h"
#include "keyboard.h"
#include "keyboard_map.h"
#include "settings.h"

static const int kButtons[] = {0, 1, 2, 3, 6, 7, 8, 9, 4, 5, 10, 11, 13, 15, 12, 14};   // A B X Y L R ZL ZR 按下左右摇杆 + - 十字键上下左右
static const int kSticks[] = {17, 19, 16, 18, 21, 23, 20, 22};                         // 左摇杆上下左右、右摇杆上下左右
static const int kCommonKeys[] = {36, 53, 49, 48, 56, 59, 58};                         // 同 Mac InputSettingsSheet.commonKeys

// 按键位显示名（同 Mac InputNames.target：A / B / X / Y / L / R / ZL / ZR 各语言相同，其余走文案）
static NSString *target_name(int t) {
    switch (t) {
        case 4: return S2AL(@"kbd.target.LS");
        case 5: return S2AL(@"kbd.target.RS");
        case 10: return S2AL(@"kbd.target.PLUS");
        case 11: return S2AL(@"kbd.target.MINUS");
        case 12: return S2AL(@"kbd.target.LEFT");
        case 13: return S2AL(@"kbd.target.UP");
        case 14: return S2AL(@"kbd.target.RIGHT");
        case 15: return S2AL(@"kbd.target.DOWN");
        case 16: return S2AL(@"kbd.target.LS_LEFT");
        case 17: return S2AL(@"kbd.target.LS_UP");
        case 18: return S2AL(@"kbd.target.LS_RIGHT");
        case 19: return S2AL(@"kbd.target.LS_DOWN");
        case 20: return S2AL(@"kbd.target.RS_LEFT");
        case 21: return S2AL(@"kbd.target.RS_UP");
        case 22: return S2AL(@"kbd.target.RS_RIGHT");
        case 23: return S2AL(@"kbd.target.RS_DOWN");
        default: return @(s2a_input_target_name(t));   // A B X Y L R ZL ZR
    }
}
// 键名同 Mac InputNames.key：修饰键前缀 ⇧⌃⌥ + 键帽
static NSString *key_name(s2a_input_key b) {
    if (b.code < 0) return S2AL(@"kbd.unbound");
    static NSDictionary<NSNumber *, NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @{@0:@"A",@1:@"S",@2:@"D",@3:@"F",@4:@"H",@5:@"G",@6:@"Z",@7:@"X",@8:@"C",@9:@"V",@11:@"B",@12:@"Q",@13:@"W",@14:@"E",@15:@"R",@16:@"Y",@17:@"T",
                 @18:@"1",@19:@"2",@20:@"3",@21:@"4",@22:@"6",@23:@"5",@24:@"=",@25:@"9",@26:@"7",@27:@"-",@28:@"8",@29:@"0",@30:@"]",@31:@"O",@32:@"U",@33:@"[",
                 @34:@"I",@35:@"P",@36:@"Return",@37:@"L",@38:@"J",@39:@"'",@40:@"K",@41:@";",@42:@"\\",@43:@",",@44:@"/",@45:@"N",@46:@"M",@47:@".",@48:@"Tab",
                 @50:@"`",@53:@"Esc",@56:@"Shift",@58:@"Option",@59:@"Ctrl",@123:@"←",@124:@"→",@125:@"↓",@126:@"↑"};
    });
    NSString *mods = [NSString stringWithFormat:@"%@%@%@", b.modifiers & 1 ? @"⇧" : @"", b.modifiers & 2 ? @"⌃" : @"", b.modifiers & 4 ? @"⌥" : @""];
    NSString *cap = b.code == 49 ? S2AL(@"kbd.key.space") : b.code == 51 ? S2AL(@"kbd.key.delete") : keys[@(b.code)];
    if (!cap) cap = [NSString stringWithFormat:S2AL(@"kbd.key.code"), @(b.code).stringValue];
    return [mods stringByAppendingString:cap];
}
static void load_saved(s2a_input_config *out) {
    NSData *data = [[s2a_ios_settings_defaults() stringForKey:S2AKeyboardMapKey] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || s2a_input_config_parse(data.bytes, data.length, out) != S2A_INPUT_CONFIG_OK) s2a_kbd_default(out);
}
int s2a_ios_keyboard_customized(void) { return [s2a_ios_settings_defaults() stringForKey:S2AKeyboardMapKey].length > 0; }

@interface S2AKeyboardSettings : UITableViewController
@property(nonatomic, copy) void (^closed)(void);
@end
@implementation S2AKeyboardSettings {
    s2a_input_config _map;
    int _recording;   // 在录的按键位；-1 = 没在录
}
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    load_saved(&_map); _recording = -1;
    self.title = S2AL(@"kbd.title");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"kbd.restoreDefault") style:UIBarButtonItemStylePlain target:self action:@selector(restoreDefault)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"kbd.restoreDefault";
    return self;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; s2a_ios_keyboard_set_muted(1); }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || !self.navigationController.presentingViewController) {
        s2a_ios_keyboard_record(NULL);
        if (self.closed) self.closed();
        self.closed = nil;
        s2a_ios_keyboard_set_muted(0);   // 虚拟按键先复位（closed），键盘再接着发
    }
}
- (void)done { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (int)targetAt:(NSIndexPath *)path { return path.section == 0 ? kButtons[path.row] : kSticks[path.row]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 16 : 8; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? S2AL(@"kbd.section.buttons") : S2AL(@"kbd.section.sticks"); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section == 1 ? S2AL(@"kbd.footer") : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    int target = [self targetAt:path];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    [self configure:cell target:target];
    cell.accessibilityIdentifier = [@"kbd.target." stringByAppendingString:@(s2a_input_target_name(target))];
    // 常用键 / 清除（同 Mac 选中按键位后的「常用键」下拉与「清除键盘按键」）
    __weak S2AKeyboardSettings *weakSelf = self;
    NSMutableArray<UIMenuElement *> *common = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kCommonKeys / sizeof *kCommonKeys; i++) {
        s2a_input_key key = {kCommonKeys[i], 0};
        [common addObject:[UIAction actionWithTitle:key_name(key) image:nil identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf bind:key to:target]; }]];
    }
    UIAction *clear = [UIAction actionWithTitle:S2AL(@"kbd.clear") image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *a) {
        (void)a; S2AKeyboardSettings *page = weakSelf; if (!page) return;
        [page stopRecording]; page->_map.keyboard[target] = (s2a_input_key){-1, 0}; [page save];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    more.menu = [UIMenu menuWithChildren:@[[UIMenu menuWithTitle:S2AL(@"kbd.common") image:[UIImage systemImageNamed:@"keyboard"] identifier:nil options:0 children:common], clear]];
    more.showsMenuAsPrimaryAction = YES;
    more.accessibilityLabel = S2AL(@"kbd.common");
    [more sizeToFit];
    cell.accessoryView = more;
    return cell;
}
// 一行的文字：按键位名 + 现在的键（在录时显示「请按新键，Esc 取消」）
- (void)configure:(UITableViewCell *)cell target:(int)target {
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = target_name(target);
    BOOL recording = _recording == target;
    c.secondaryText = recording ? S2AL(@"kbd.record") : key_name(_map.keyboard[target]);
    if (recording) c.secondaryTextProperties.color = self.view.tintColor;
    cell.contentConfiguration = c;
}
// 键位变了：只就地改看得见的行的文字，不整表重建（行高是估算的，整表重建会让列表跳一截；真机 11-21 用「…」菜单改键后整体下移约两行）
- (void)refreshVisibleRows {
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (cell) [self configure:cell target:[self targetAt:path]];
    }
}
// 点按键位：开始录（再点一次同一行取消）
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    int target = [self targetAt:path];
    if (_recording == target) { [self stopRecording]; return; }
    [self stopRecording];
    _recording = target;
    [self refreshVisibleRows];
    __weak S2AKeyboardSettings *weakSelf = self;
    s2a_ios_keyboard_record(^(int code, unsigned modifiers) {
        S2AKeyboardSettings *page = weakSelf;
        if (!page || page->_recording != target) return;
        [page stopRecording];
        if (code >= 0) [page bind:(s2a_input_key){code, modifiers} to:target];   // Esc = 取消
    });
}
- (void)stopRecording {
    if (_recording < 0) return;
    _recording = -1;
    s2a_ios_keyboard_record(NULL);
    [self refreshVisibleRows];
}
// 绑键：别的按键位已经用了这个键就先问（同 Mac「改绑这个键？」）
- (void)bind:(s2a_input_key)key to:(int)target {
    [self stopRecording];
    int holder = -1;
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++)
        if (t != target && _map.keyboard[t].code == key.code && _map.keyboard[t].modifiers == key.modifiers) holder = t;
    if (holder < 0) { _map.keyboard[target] = key; [self save]; return; }
    NSString *body = [NSString stringWithFormat:S2AL(@"kbd.rebind.body"), target_name(holder), target_name(target), key_name(key)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"kbd.rebind.title") message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak S2AKeyboardSettings *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"kbd.rebind.confirm") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; S2AKeyboardSettings *page = weakSelf; if (!page) return;
        page->_map.keyboard[holder] = (s2a_input_key){-1, 0};
        page->_map.keyboard[target] = key;
        [page save];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)restoreDefault {
    [self stopRecording];
    s2a_kbd_default(&_map);
    [self save];
}
// 存：与缺省相同就删掉（这款回到缺省，以后缺省改了跟着走）；否则按款存 schema 1 JSON。存完当场生效
- (void)save {
    s2a_input_config def; s2a_kbd_default(&def);
    NSUserDefaults *defaults = s2a_ios_settings_defaults();
    char json[4096];
    int n = memcmp(&def, &_map, sizeof def) ? s2a_kbd_config_json(&_map, json, sizeof json) : 0;
    if (n > 0) [defaults setObject:[[NSString alloc] initWithBytes:json length:(NSUInteger)n encoding:NSUTF8StringEncoding] forKey:S2AKeyboardMapKey];
    else [defaults removeObjectForKey:S2AKeyboardMapKey];
    s2a_ios_keyboard_reload();
    [self refreshVisibleRows];
}
@end

UIViewController *s2a_ios_keyboard_settings(void (^closed)(void)) {
    S2AKeyboardSettings *page = [S2AKeyboardSettings new];
    page.closed = closed;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.modalInPresentation = YES;
    return navigation;
}
