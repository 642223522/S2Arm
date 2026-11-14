#!/usr/bin/env python3
# Mario cartoon touch-control skin (this fork's customization).
#
# Restyles S2Arm's virtual gamepad to the approved cartoon Mario look:
# thick ink outlines, flat bright fills (A red, B coin gold, X sky blue,
# Y Luigi green, brick-orange shoulders, cream +/-, slate d-pad with gold
# arrows), mushroom-spotted stick ring and a Mario-cap stick knob.
#
# Scope: only the DEFAULT pad theme (g_theme == 0) in ios/vpad.m; the
# built-in color themes 1-4 keep their stock look. The settings preview
# (shell/Sources/ShellUI/TouchControlsPreview.swift) is restyled to match.
# Positions/sizes are the engine's own and are not touched.
#
# Every replacement is an exact-match anchor: if upstream code drifts,
# this script fails loudly instead of silently shipping the stock look.

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

VPAD_EDITS = [
    # 1) Skin palette helpers + ink outline for the default theme.
    (
        "static UIColor *vp_line(void) { return g_theme ? vp_theme(0.85) : [UIColor colorWithWhite:1 alpha:0.78]; }",
        """// Mario cartoon skin (this fork's customization; default theme g_theme == 0 only, themes 1-4 keep the stock look): thick ink outlines + flat bright fills.
static UIColor *vp_ink(void) { return [UIColor colorWithRed:0.17 green:0.13 blue:0.21 alpha:0.92]; }
static UIColor *vp_keybg(NSInteger tag, BOOL pressed) {
    CGFloat r, g, b;
    switch (tag) {
        case 0: r = 0.906; g = 0.251; b = 0.180; break;                          // A Mario red
        case 1: r = 0.961; g = 0.722; b = 0.114; break;                          // B coin gold
        case 2: r = 0.180; g = 0.608; b = 0.902; break;                          // X sky blue
        case 3: r = 0.216; g = 0.698; b = 0.302; break;                          // Y Luigi green
        case 6: case 7: case 8: case 9: r = 0.894; g = 0.341; b = 0.180; break;  // L / R / ZL / ZR brick orange
        case 10: case 11: r = 1.000; g = 0.945; b = 0.812; break;                // PLUS / MINUS cream
        default: r = 0.227; g = 0.247; b = 0.290; break;                         // LS / RS / d-pad slate
    }
    if (pressed) { r += (1 - r) * 0.35; g += (1 - g) * 0.35; b += (1 - b) * 0.35; }
    return [UIColor colorWithRed:r green:g blue:b alpha:0.96];
}
static UIColor *vp_line(void) { return g_theme ? vp_theme(0.85) : vp_ink(); }""",
    ),
    # 2) Face-button letters: white on the colored domes (was pale cyan).
    (
        "static UIColor *vp_face(void) { return g_theme ? vp_theme(0.95) : [UIColor colorWithRed:150 / 255.0 green:215 / 255.0 blue:230 / 255.0 alpha:0.9]; }",
        "static UIColor *vp_face(void) { return g_theme ? vp_theme(0.95) : [UIColor colorWithWhite:1 alpha:0.96]; }",
    ),
    # 3) Pressed/rest fill comes from the skin palette in the default theme.
    (
        "static void vp_fill(UIView *key, BOOL pressed) { key.layer.backgroundColor = pressed ? [UIColor colorWithWhite:1 alpha:0.3].CGColor : NULL; }",
        "static void vp_fill(UIView *key, BOOL pressed) { key.layer.backgroundColor = g_theme ? (pressed ? [UIColor colorWithWhite:1 alpha:0.3].CGColor : NULL) : vp_keybg(key.tag, pressed).CGColor; }",
    ),
    # 4) rebuildKeys: thicker ink border; ink glyphs on the cream pills, gold arrows on the d-pad.
    (
        "        key.backgroundColor = UIColor.clearColor; vp_fill(key, NO); key.layer.borderWidth = 1.6; key.layer.borderColor = vp_line().CGColor;",
        """        key.backgroundColor = UIColor.clearColor; vp_fill(key, NO); key.layer.borderWidth = g_theme ? 1.6 : 2.6; key.layer.borderColor = vp_line().CGColor;
        if (!g_theme && (key.tag == B_PLUS || key.tag == B_MINUS)) key.textColor = vp_ink();
        if (!g_theme && key.tag >= B_LEFT) key.textColor = [UIColor colorWithRed:1 green:0.788 blue:0.235 alpha:0.98];""",
    ),
    # 5) Leaving the layout editor restores the border width: keep the ink weight.
    (
        "    for (UILabel *l in _keys) { l.layer.borderColor = vp_line().CGColor; l.layer.borderWidth = 1.5; }",
        "    for (UILabel *l in _keys) { l.layer.borderColor = vp_line().CGColor; l.layer.borderWidth = g_theme ? 1.5 : 2.6; }",
    ),
    # 6) Sticks: red mushroom-spotted ring + Mario-cap knob (default theme only).
    (
        "        _ring[i].alpha = _knob[i].alpha = vp_opacity();",
        """        _ring[i].alpha = _knob[i].alpha = vp_opacity();
        // Mario skin (default theme): stick ring = red with white mushroom spots; knob = Mario cap (red dome, white badge, red M).
        if (!g_theme) {
            _ring[i].layer.borderWidth = 2.6; _ring[i].layer.borderColor = vp_ink().CGColor;
            _ring[i].backgroundColor = [UIColor colorWithRed:0.847 green:0.212 blue:0.165 alpha:0.9];
            static const CGFloat vpSpots[5][2] = {{30, 26}, {86, 20}, {98, 74}, {52, 92}, {18, 82}};
            for (int s = 0; s < 5; s++) { UIView *sp = [[UIView alloc] initWithFrame:CGRectMake(vpSpots[s][0], vpSpots[s][1], 13, 13)]; sp.layer.cornerRadius = 6.5; sp.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95]; sp.userInteractionEnabled = NO; sp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin; [_ring[i] addSubview:sp]; }
            _knob[i].layer.borderWidth = 2.6; _knob[i].layer.borderColor = vp_ink().CGColor;
            _knob[i].backgroundColor = [UIColor colorWithRed:0.906 green:0.251 blue:0.180 alpha:0.97];
            UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(9, 9, 34, 34)]; badge.text = @"M"; badge.textAlignment = NSTextAlignmentCenter;
            badge.font = [UIFont boldSystemFontOfSize:19]; badge.textColor = [UIColor colorWithRed:0.847 green:0.212 blue:0.165 alpha:1];
            badge.backgroundColor = UIColor.whiteColor; badge.layer.cornerRadius = 17; badge.layer.masksToBounds = YES; badge.userInteractionEnabled = NO;
            badge.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [_knob[i] addSubview:badge];
        }""",
    ),
]

SWIFT_OLD_DRAW = """    static func draw(_ shape: TouchPadPreviewGeometry.Shape, in context: inout GraphicsContext, style: Style = Style()) {
        func key(_ path: Path) { context.fill(path, with: .color(style.fill)); context.stroke(path, with: .color(style.line), lineWidth: style.lineWidth) }
        func label(_ s: String, _ c: CGPoint, _ size: CGFloat) {
            context.draw(Text(verbatim: s).font(.system(size: size, weight: .semibold)).foregroundStyle(style.text), at: c)
        }
        switch shape {
        case .circle(let c, let r, let name):
            key(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
            if let name { label(name, c, r * 0.75) }
        case .ring(let c, let r, let knob):
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(ring, with: .color(style.ring)); context.stroke(ring, with: .color(style.line), lineWidth: style.lineWidth)
            key(Path(ellipseIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob)))
        case .drop(let c, let r, let right, let name):
            key(dropPath(c, r, right))
            label(name, c, r * 0.62)
        case .pill(let rect, let name):
            key(Path(roundedRect: rect, cornerRadius: rect.height / 2))
            label(name, CGPoint(x: rect.midX, y: rect.midY), rect.height * 0.64)
        case .dpad(let c, let r):
            key(dpadPath(c, r))
        }
    }"""

SWIFT_NEW_DRAW = """    // Mario cartoon skin (this fork's customization, mirroring ios/vpad.m): thick ink outlines, flat bright fills.
    static let ink = Color(red: 0.17, green: 0.13, blue: 0.21)
    static let mRed = Color(red: 0.906, green: 0.251, blue: 0.180)
    static let mGold = Color(red: 0.961, green: 0.722, blue: 0.114)
    static let mBlue = Color(red: 0.180, green: 0.608, blue: 0.902)
    static let mGreen = Color(red: 0.216, green: 0.698, blue: 0.302)
    static let mBrick = Color(red: 0.894, green: 0.341, blue: 0.180)
    static let mSlate = Color(red: 0.227, green: 0.247, blue: 0.290)
    static let mCream = Color(red: 1.0, green: 0.945, blue: 0.812)
    static let mRingRed = Color(red: 0.847, green: 0.212, blue: 0.165)

    static func draw(_ shape: TouchPadPreviewGeometry.Shape, in context: inout GraphicsContext, style: Style = Style()) {
        func key(_ path: Path, _ fill: Color) { context.fill(path, with: .color(fill)); context.stroke(path, with: .color(ink), lineWidth: 2.6) }
        func label(_ s: String, _ c: CGPoint, _ size: CGFloat, _ color: Color = .white) {
            context.draw(Text(verbatim: s).font(.system(size: size, weight: .bold)).foregroundStyle(color), at: c)
        }
        switch shape {
        case .circle(let c, let r, let name):
            let fill: Color
            switch name {
            case "A": fill = mRed
            case "B": fill = mGold
            case "X": fill = mBlue
            case "Y": fill = mGreen
            default: fill = mSlate
            }
            key(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), fill)
            if let name { label(name, c, r * 0.75) } else { label("?", c, r * 0.9, ink) }
        case .ring(let c, let r, let knob):
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(ring, with: .color(mRingRed)); context.stroke(ring, with: .color(ink), lineWidth: 2.6)
            for spot in [CGPoint(x: -0.55, y: -0.45), CGPoint(x: 0.5, y: -0.6), CGPoint(x: 0.62, y: 0.3), CGPoint(x: -0.15, y: 0.58), CGPoint(x: -0.62, y: 0.42)] {
                let sc = CGPoint(x: c.x + spot.x * r, y: c.y + spot.y * r), sr = r * 0.11
                context.fill(Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - sr, width: 2 * sr, height: 2 * sr)), with: .color(.white.opacity(0.95)))
            }
            key(Path(ellipseIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob)), mRed)
            let badge = Path(ellipseIn: CGRect(x: c.x - knob * 0.62, y: c.y - knob * 0.62, width: knob * 1.24, height: knob * 1.24))
            context.fill(badge, with: .color(.white))
            label("M", c, knob * 0.85, mRingRed)
        case .drop(let c, let r, let right, let name):
            key(dropPath(c, r, right), mBrick)
            label(name, c, r * 0.62)
        case .pill(let rect, let name):
            key(Path(roundedRect: rect, cornerRadius: rect.height / 2), mCream)
            label(name, CGPoint(x: rect.midX, y: rect.midY), rect.height * 0.64, ink)
        case .dpad(let c, let r):
            key(dpadPath(c, r), mSlate)
            let coin = Path(ellipseIn: CGRect(x: c.x - r * 0.16, y: c.y - r * 0.16, width: r * 0.32, height: r * 0.32))
            context.fill(coin, with: .color(mGold)); context.stroke(coin, with: .color(ink), lineWidth: 1.6)
        }
    }"""


def apply_edits(path: pathlib.Path, edits) -> None:
    text = path.read_text(encoding="utf-8")
    for old, new in edits:
        n = text.count(old)
        if n != 1:
            print(f"FAIL: anchor found {n}x (expected 1) in {path}:\n  {old[:90]}...")
            sys.exit(1)
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
    print(f"patched {path.relative_to(ROOT)} ({len(edits)} edits)")


def main() -> None:
    apply_edits(ROOT / "ios" / "vpad.m", VPAD_EDITS)
    apply_edits(
        ROOT / "shell" / "Sources" / "ShellUI" / "TouchControlsPreview.swift",
        [(SWIFT_OLD_DRAW, SWIFT_NEW_DRAW)],
    )
    print("mario skin applied")


if __name__ == "__main__":
    main()
