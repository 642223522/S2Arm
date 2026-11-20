// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "LauncherPadBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static id legacy(id e, NSAccessibilityAttributeName name) {
    return [e respondsToSelector:@selector(accessibilityAttributeValue:)] ? [e accessibilityAttributeValue:name] : nil;
}

@implementation S2ALauncherAX
+ (NSArray *)children:(id)e {
    NSArray *children = [e respondsToSelector:@selector(accessibilityChildren)] ? [(id<NSAccessibility>)e accessibilityChildren] : nil;
    return children.count ? children : legacy(e, NSAccessibilityChildrenAttribute) ?: @[];
}
+ (NSString *)role:(id)e { return [e respondsToSelector:@selector(accessibilityRole)] ? [(id<NSAccessibility>)e accessibilityRole] ?: @"" : @""; }
+ (NSString *)identifier:(id)e {
    NSString *value = [e respondsToSelector:@selector(accessibilityIdentifier)] ? [(id<NSAccessibility>)e accessibilityIdentifier] : nil;
    return value.length ? value : legacy(e, NSAccessibilityIdentifierAttribute) ?: @"";
}
+ (NSString *)label:(id)e {
    id<NSAccessibility> a = e;
    if ([e respondsToSelector:@selector(accessibilityLabel)] && a.accessibilityLabel.length) return a.accessibilityLabel;
    return [e respondsToSelector:@selector(accessibilityTitle)] ? a.accessibilityTitle ?: @"" : @"";
}
+ (NSRect)frame:(id)e { return [e respondsToSelector:@selector(accessibilityFrame)] ? [(id<NSAccessibility>)e accessibilityFrame] : NSZeroRect; }
+ (BOOL)enabled:(id)e { return ![e respondsToSelector:@selector(isAccessibilityEnabled)] || [(id<NSAccessibility>)e isAccessibilityEnabled]; }
+ (id)value:(id)e {
    id control = [e isKindOfClass:NSCell.class] ? [(NSCell *)e controlView] : e;
    if ([control isKindOfClass:NSTextField.class]) return [(NSTextField *)control stringValue];
    return [e respondsToSelector:@selector(accessibilityValue)] ? [(id<NSAccessibility>)e accessibilityValue] : nil;
}
+ (BOOL)secure:(id)e {
    id control = [e isKindOfClass:NSCell.class] ? [(NSCell *)e controlView] : e;
    if ([control isKindOfClass:NSSecureTextField.class]) return YES;
    return [e respondsToSelector:@selector(accessibilitySubrole)] && [[(id<NSAccessibility>)e accessibilitySubrole] isEqualToString:NSAccessibilitySecureTextFieldSubrole];
}
+ (void)setValue:(id)v element:(id)e {
    id control = [e isKindOfClass:NSCell.class] ? [(NSCell *)e controlView] : e;
    if ([control isKindOfClass:NSTextField.class]) {
        NSTextField *field = control;
        field.stringValue = [v isKindOfClass:NSString.class] ? v : [v description];
        if (field.currentEditor) field.currentEditor.string = field.stringValue;
        // Changing a cell's AX value alone does not notify SwiftUI's coordinator.
        // Use the same public text-editing delegate event as native text entry.
        NSNotification *change = [NSNotification notificationWithName:NSControlTextDidChangeNotification object:field];
        if ([field.delegate respondsToSelector:@selector(controlTextDidChange:)]) [field.delegate controlTextDidChange:change];
        return;
    }
    if ([e respondsToSelector:@selector(setAccessibilityValue:)]) [(id<NSAccessibility>)e setAccessibilityValue:v];
}
+ (void)focus:(id)e { if ([e respondsToSelector:@selector(setAccessibilityFocused:)]) [(id<NSAccessibility>)e setAccessibilityFocused:YES]; }
+ (BOOL)press:(id)e {
    if ([e respondsToSelector:@selector(accessibilityPerformPress)] && [(id<NSAccessibility>)e accessibilityPerformPress]) return YES;
    return [e respondsToSelector:@selector(accessibilityPerformShowMenu)] && [(id<NSAccessibility>)e accessibilityPerformShowMenu];
}
+ (BOOL)adjust:(id)e step:(NSInteger)step {
    if (step > 0) return [e respondsToSelector:@selector(accessibilityPerformIncrement)] && [(id<NSAccessibility>)e accessibilityPerformIncrement];
    return [e respondsToSelector:@selector(accessibilityPerformDecrement)] && [(id<NSAccessibility>)e accessibilityPerformDecrement];
}
+ (BOOL)pick:(id)e { return [e respondsToSelector:@selector(accessibilityPerformPick)] && [(id<NSAccessibility>)e accessibilityPerformPick]; }
+ (BOOL)cancel:(id)e { return [e respondsToSelector:@selector(accessibilityPerformCancel)] && [(id<NSAccessibility>)e accessibilityPerformCancel]; }
@end
#pragma clang diagnostic pop
