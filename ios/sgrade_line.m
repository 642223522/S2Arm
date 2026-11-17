// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "sgrade_line.h"
#import "s2a_l10n.h"

int s2a_sgrade_version_cmp(NSString *a, NSString *b) {
    NSArray<NSString *> *x = [a componentsSeparatedByString:@"."], *y = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger p = i < x.count ? x[i].integerValue : 0, q = i < y.count ? y[i].integerValue : 0;
        if (p != q) return p < q ? -1 : 1;
    }
    return 0;
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }

NSString *s2a_sgrade_line(NSString *cat, NSDictionary *s, NSString *catName, NSInteger fpsTarget,
                          NSString *(^date)(NSDate *when)) {
    if (![s isKindOfClass:NSDictionary.class]) return nil;
    NSString *state = str(s[@"state"]);
    if ([state isEqual:@"on"]) {
        if ([cat isEqual:@"fps"]) return fpsTarget > 0 ? [NSString stringWithFormat:S2AL(@"sgrade.state.on.fps"), [@(fpsTarget) stringValue]] : nil;
        if (![cat isEqual:@"widescreen"]) return nil;
        NSString *active = str(s[@"active"]);
        if ([str(s[@"source"]) isEqual:@"own"] || [active isEqual:@"own"]) return S2AL(@"sgrade.state.on.own");
        return [active isEqual:@"fixed"] ? S2AL(@"sgrade.state.on.fixed") : S2AL(@"sgrade.state.on.adaptive");
    }
    if ([state isEqual:@"ineffective"]) { NSString *r = str(s[@"lastRun"]); return r.length ? r : nil; }   // 原句本身就写「没生效：…」，不再套一层
    if ([state isEqual:@"off_user"]) return S2AL(@"sgrade.state.off_user");
    if ([state isEqual:@"off_auto"]) {
        NSDictionary *off = [s[@"autoOff"] isKindOfClass:NSDictionary.class] ? s[@"autoOff"] : nil;
        NSNumber *at = [off[@"at"] isKindOfClass:NSNumber.class] ? off[@"at"] : nil;
        NSString *when = at.doubleValue > 0 ? date([NSDate dateWithTimeIntervalSince1970:at.doubleValue]) : @"";
        NSString *cause = str(off[@"cause"]);   // crash 游戏崩溃 / stall 画面停住 / widen_fit 手动开的通用满屏局内没铺满或被拉伸
        return [NSString stringWithFormat:([cause isEqual:@"stall"] ? S2AL(@"sgrade.state.off_auto.stall") : [cause isEqual:@"widen_fit"] ? S2AL(@"sgrade.state.off_auto.widen_fit")
                                           : S2AL(@"sgrade.state.off_auto.crash")), when];
    }
    if ([state isEqual:@"version"]) {
        // 维护者 11-15 定：写离玩家最近、且比它新的那个版本；全是旧版本写「只有旧版本 X 的」，不劝降级
        NSDictionary *v = [s[@"versions"] isKindOfClass:NSDictionary.class] ? s[@"versions"] : @{};
        NSString *mine = str(v[@"mine"]); NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (id x in [v[@"available"] isKindOfClass:NSArray.class] ? v[@"available"] : @[]) if ([x isKindOfClass:NSString.class]) [all addObject:x];
        if (!all.count) return nil;
        [all sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return (NSComparisonResult)s2a_sgrade_version_cmp(a, b); }];
        NSString *newer = nil; for (NSString *x in all) if (s2a_sgrade_version_cmp(x, mine) > 0) { newer = x; break; }
        NSString *text = newer ? [NSString stringWithFormat:S2AL(@"sgrade.state.version.newer"), newer, mine]
                               : [NSString stringWithFormat:S2AL(@"sgrade.state.version.older"), all.lastObject];
        if ([cat isEqual:@"widescreen"] && [str(v[@"port"]) isEqual:@"failed"]) text = [text stringByAppendingString:S2AL(@"sgrade.state.version.port_failed")];
        return text;
    }
    if ([state isEqual:@"failed"]) {   // 补丁库有、出包时一份没打进去（11-15 #934）：如实写原因（作业层 sgrade.write_kit_state 的 fps.failed）
        NSArray *fl = [s[@"failed"] isKindOfClass:NSArray.class] ? s[@"failed"] : @[];
        NSString *why = fl.count && [fl[0] isKindOfClass:NSDictionary.class] ? str(fl[0][@"why"]) : @"";
        // 原因键逐个写字面量（文案检查只认字面量键，tests/ios_l10n_test.sh ②）；同作业层 pack/jobs/patches.py _WHY
        NSString *reason = [why isEqual:@"result.why.conflict"] ? S2AL(@"sgrade.result.why.conflict") : [why isEqual:@"result.why.translate"] ? S2AL(@"sgrade.result.why.translate")
            : [why isEqual:@"result.why.full"] ? S2AL(@"sgrade.result.why.full") : [why isEqual:@"result.why.port"] ? S2AL(@"sgrade.result.why.port")
            : [why isEqual:@"result.why.version"] ? S2AL(@"sgrade.result.why.version") : [why isEqual:@"result.why.unsupported"] ? S2AL(@"sgrade.result.why.unsupported")
            : S2AL(@"sgrade.result.why.mismatch");
        return [NSString stringWithFormat:S2AL(@"sgrade.state.failed"), catName, reason];
    }
    if ([state isEqual:@"none"]) return [NSString stringWithFormat:S2AL(@"sgrade.state.none"), catName];
    if ([state isEqual:@"opted_out"]) return S2AL(@"sgrade.state.opted_out");
    if ([state isEqual:@"pending"]) return S2AL(@"sgrade.state.pending.ios");   // iPhone 补不上：要回电脑点「S 级优化升级」（Mac 下次起局自动补，不说）
    if ([state isEqual:@"mac_only"]) return S2AL(@"sgrade.state.mac_only");
    return nil;
}

NSString *s2a_sgrade_row_note(NSString *cat, NSDictionary *s, NSInteger fpsTarget, BOOL hasFpsPatch, BOOL fpsPatchOn, BOOL fiSupported,
                              NSString *(^date)(NSDate *when), BOOL *disabled) {
    if (disabled) *disabled = NO;
    NSDictionary *st = [s isKindOfClass:NSDictionary.class] ? s : @{};
    NSString *state = str(st[@"state"]);
    // 状态句优先：被自动关、上一局没生效、出包时没打入——这些比「用的是什么」要紧
    if ([state isEqual:@"off_auto"] || [state isEqual:@"ineffective"] || [state isEqual:@"opted_out"]) {
        NSString *line = s2a_sgrade_line(cat, st, @"", fpsTarget, date); if (line) return line;
    }
    if ([cat isEqual:@"widescreen"]) {
        // 没有社区满屏补丁的款一律走 S2Arm 通用满屏（11-15 起不看名单）
        if ([str(st[@"source"]) isEqual:@"patch"])
            return [str(st[@"active"]) isEqual:@"fixed"] ? S2AL(@"sgrade.src.fs.fixed") : S2AL(@"sgrade.src.fs.adaptive");
        return S2AL(@"sgrade.src.fs.own");
    }
    if ([cat isEqual:@"fps"]) {
        // 一个开关取最好的来源（作业层 fps.source：patch / fi / none；没这个字段时按本机：补丁开关开着且有补丁 = patch，否则能补帧 = fi）
        NSString *src = str(st[@"source"]);
        id fs = st[@"fiSupported"]; BOOL fi = [fs isKindOfClass:NSNumber.class] ? [fs boolValue] : fiSupported;
        if ([state isEqual:@"unsupported"]) { if (disabled) *disabled = YES; return S2AL(@"sgrade.unavail.fi"); }   // 没补丁又不能补帧（作业层定）
        if ([state isEqual:@"failed"]) {   // 帧率补丁没打进去：写原因；还能补帧就不置灰（开关管补帧）
            NSString *line = s2a_sgrade_line(cat, st, S2AL(@"cpatch.group.fps"), fpsTarget, date);
            if (line) { if (disabled) *disabled = !fi; return line; }
        }
        if (!src.length) src = hasFpsPatch && fpsPatchOn ? @"patch" : fi ? @"fi" : @"none";
        NSString *patchLine = fpsTarget > 0 ? [NSString stringWithFormat:S2AL(@"sgrade.src.fps.patch"), [@(fpsTarget) stringValue]] : nil;
        NSString *fiLine = hasFpsPatch ? S2AL(@"sgrade.src.fps.fi") : S2AL(@"sgrade.src.fps.fi.nopatch");
        if ([src isEqual:@"patch"]) return patchLine ?: fiLine;
        if ([src isEqual:@"fi"]) return fiLine;
        // 关着：写打开后用什么；真用不了（没补丁、设备不支持补帧）才置灰
        if (hasFpsPatch) return patchLine;
        if (fi) return fiLine;
        if (disabled) *disabled = YES;
        return S2AL(@"sgrade.unavail.fi");
    }
    return nil;
}
