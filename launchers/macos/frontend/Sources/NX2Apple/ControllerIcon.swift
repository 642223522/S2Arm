// S2Arm（不是上游文件）：手柄图示，照 #520 UI 稿的 SVG（#520 UI 稿 的 symbol：i1 / i1l / i2 / pair / two-v / ipro）一比一画，
//   坐标就是稿里 viewBox 的坐标（Joy-Con 60×40、Pro 64×44），按显示尺寸等比缩放。Joy-Con 2 深灰机身、左只蓝边、右只红边
import SwiftUI

/// 手柄自己报的颜色（RGB，0xRRGGBB）：一代 Joy-Con 读 SPI 0x6050（机身 + 按键）；Joy-Con 2 是边条色。没读到就用 ControllerIcon 的缺省色
struct ControllerTint: Hashable {
    var body: UInt32
    var buttons: UInt32?
    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
    /// 描边：同色压暗（不必每种颜色各配一张图）
    static func edge(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 0xff) / 255 * 0.78, green: Double(rgb >> 8 & 0xff) / 255 * 0.78, blue: Double(rgb & 0xff) / 255 * 0.78)
    }
}
/// 一位玩家的手柄颜色：左只 / 右只（单只、Pro 只用到一边）。nil = 缺省色（第三方手柄、还没读到）
struct ControllerColors: Equatable {
    var left: ControllerTint?
    var right: ControllerTint?
    static let none = ControllerColors()
}

struct ControllerIcon: View {
    enum Glyph { case left, right, leftSideways, rightSideways, gen1LeftSideways, gen1RightSideways, pairHead, pro, pro2, unknown, playstation, xbox, gen1Left, gen1Right, gen1Pair, otherPad, keyboard,
        /// 预留给未来同一 Wi-Fi 的手机当手柄（玩家位走分配玩家流程，不写死）。功能未做，面板暂不显示、也不引用
        ///   方案建议（入口、配对、玩家、顶栏）写在 Switch2ProConnectionPopover.swift 文件头：放进手柄弹窗，不另开首页面板
        mobile }
    let glyph: Glyph
    var colors: ControllerColors = .none

    /// 按连接程序报的型号挑图（ns2_kind：1 Pro、2 左、3 右、4 一对；players 2 = 两只各一位玩家，标题图同一对）
    /// 玩家列表里的一位：单只 Joy-Con 横着画（它就是一位玩家、横握），其余同标题图
    static func player(kind: Int) -> Glyph? {
        switch kind { case 2: return .leftSideways; case 3: return .rightSideways; default: return header(kind: kind, players: 1) }
    }
    static func header(kind: Int, players: Int) -> Glyph? {
        if players == 2 || kind == 4 { return .pairHead }
        switch kind { case 1: return .pro2; case 2: return .left; case 3: return .right; default: return nil }   // 连接程序报的 Pro = Switch 2 Pro
    }

    var body: some View {
        Canvas { context, size in
            let wide: Set<Glyph> = [.pro, .pro2, .playstation, .xbox, .otherPad, .unknown, .keyboard, .mobile]
            let box: CGSize = wide.contains(glyph) ? CGSize(width: 64, height: 44) : CGSize(width: 60, height: 40)
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            switch glyph {
            case .left: Self.half(&context, left: true, inner: 40, tint: colors.left)
            // 单只当一位玩家：横着画（同握法）——左只逆时针、右只顺时针转 90°，两种摇杆都在左边
            case .leftSideways, .rightSideways, .gen1LeftSideways, .gen1RightSideways:
                let left = glyph == .leftSideways || glyph == .gen1LeftSideways
                context.translateBy(x: 30, y: 20); context.rotate(by: .degrees(left ? -90 : 90)); context.translateBy(x: -30, y: -20)
                Self.half(&context, left: left, inner: left ? 40 : 20, gen1: glyph == .gen1LeftSideways || glyph == .gen1RightSideways, tint: left ? colors.left : colors.right)
            case .right: Self.half(&context, left: false, inner: 20, tint: colors.right)
            case .pairHead: Self.half(&context, left: true, inner: 29, tint: colors.left); Self.half(&context, left: false, inner: 31, tint: colors.right)
            case .pro: Self.proPad(&context, switch2: false)    // Switch Pro（一代）
            case .pro2: Self.proPad(&context, switch2: true)    // Switch 2 Pro
            case .unknown: Self.unknown(&context)
            case .keyboard: Self.keyboardGlyph(&context)
            case .mobile: Self.mobileGlyph(&context)
            case .playstation: Self.pad(&context, body: Color(white: 0.95), touchpad: true, guide: nil)
            case .xbox: Self.pad(&context, body: Color(white: 0.95), touchpad: false, guide: Color(red: 0x10 / 255, green: 0x7c / 255, blue: 0x10 / 255))
            case .otherPad: Self.generic(&context)   // 认不出 / 第三方手柄：缺省的白色手柄图
            case .gen1Left: Self.half(&context, left: true, inner: 40, gen1: true, tint: colors.left)
            case .gen1Right: Self.half(&context, left: false, inner: 20, gen1: true, tint: colors.right)
            case .gen1Pair: Self.half(&context, left: true, inner: 29, gen1: true, tint: colors.left); Self.half(&context, left: false, inner: 31, gen1: true, tint: colors.right)
            }
        }
    }

    static let leftAccent = Color(red: 0x41 / 255, green: 0xb8 / 255, blue: 0xe8 / 255)    // --l
    static let rightAccent = Color(red: 0xef / 255, green: 0x5a / 255, blue: 0x5a / 255)   // --r
    private static let shell = Color(red: 0x3b / 255, green: 0x3b / 255, blue: 0x3f / 255)
    private static let shellEdge = Color(red: 0x62 / 255, green: 0x61 / 255, blue: 0x66 / 255)
    private static let stickFill = Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255)
    private static let key = Color(red: 0xe2 / 255, green: 0xdf / 255, blue: 0xd9 / 255)

    /// 一只 Joy-Con：inner 是贴中间那条直边的 x；机身宽 20、外侧圆角 10，内侧 3.2 宽的色条，摇杆 / 四键 / −（左）或 +（右）
    ///   tint：手柄报的颜色（一代 = 机身 + 按键；Joy-Con 2 = 边条与摇杆圈），nil 用缺省色
    private static func half(_ c: inout GraphicsContext, left: Bool, inner x: CGFloat, gen1: Bool = false, tint: ControllerTint? = nil) {
        let outer = left ? x - 20 : x + 20
        var body = Path()
        body.move(to: CGPoint(x: x, y: 1))
        body.addLine(to: CGPoint(x: left ? outer + 10 : outer - 10, y: 1))
        body.addArc(center: CGPoint(x: left ? outer + 10 : outer - 10, y: 11), radius: 10,
                    startAngle: .degrees(-90), endAngle: .degrees(left ? 180 : 0), clockwise: left)
        body.addLine(to: CGPoint(x: outer, y: 29))
        body.addArc(center: CGPoint(x: left ? outer + 10 : outer - 10, y: 29), radius: 10,
                    startAngle: .degrees(left ? 180 : 0), endAngle: .degrees(90), clockwise: left)
        body.addLine(to: CGPoint(x: x, y: 39))
        body.closeSubpath()
        // 一代 Joy-Con（稿里 ijcl1）：整只彩色机身（左蓝 #0ab9e6、右红 #ff3c28）、没有色条，摇杆和键是深色
        //   读到颜色时整只换成手柄自己的颜色，描边同色压暗
        let gen1Body = tint.map { ControllerTint.color($0.body) } ?? (left ? Color(red: 0x0a / 255, green: 0xb9 / 255, blue: 0xe6 / 255) : Color(red: 0xff / 255, green: 0x3c / 255, blue: 0x28 / 255))
        let gen1Edge = tint.map { ControllerTint.edge($0.body) } ?? (left ? Color(red: 0x07 / 255, green: 0x94 / 255, blue: 0xbb / 255) : Color(red: 0xc9 / 255, green: 0x2a / 255, blue: 0x1b / 255))
        c.fill(body, with: .color(gen1 ? gen1Body : shell))
        c.stroke(body, with: .color(gen1 ? gen1Edge : shellEdge), lineWidth: 1)
        let accent = tint.map { ControllerTint.color($0.body) } ?? (left ? leftAccent : rightAccent)
        if !gen1 { c.fill(Path(roundedRect: CGRect(x: left ? x - 3.2 : x, y: 1, width: 3.2, height: 38), cornerRadius: 1.4), with: .color(accent)) }
        let cx = left ? x - 11.5 : x + 11.5
        let stick = CGRect(x: cx - 4.6, y: (left ? 13 : 28) - 4.6, width: 9.2, height: 9.2)
        c.fill(Path(ellipseIn: stick), with: .color(stickFill))
        if gen1 { c.fill(Path(ellipseIn: stick.insetBy(dx: 2, dy: 2)), with: .color(Color(red: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255))) }
        else { c.stroke(Path(ellipseIn: stick), with: .color(accent), lineWidth: 1.9) }
        let keyColor = gen1 ? (tint?.buttons.map(ControllerTint.color) ?? stickFill) : key
        let keys = CGPoint(x: cx, y: left ? 28 : 13)
        for (dx, dy) in [(0.0, -3.6), (3.6, 0.0), (0.0, 3.6), (-3.6, 0.0)] {
            c.fill(Path(ellipseIn: CGRect(x: keys.x + dx - 1.7, y: keys.y + dy - 1.7, width: 3.4, height: 3.4)), with: .color(keyColor))
        }
        var sign = Path()
        let sx = left ? x - 8.4 : x + 5.6
        sign.move(to: CGPoint(x: sx, y: 4.6)); sign.addLine(to: CGPoint(x: sx + 2.8, y: 4.6))
        if !left { sign.move(to: CGPoint(x: sx + 1.4, y: 3.2)); sign.addLine(to: CGPoint(x: sx + 1.4, y: 6)) }
        c.stroke(sign, with: .color(keyColor), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    /// 系统手柄外形（稿里 ips 的轮廓，viewBox 64×44）
    private static func padPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 8)); p.addLine(to: CGPoint(x: 50, y: 8))
        p.addCurve(to: CGPoint(x: 63, y: 25), control1: CGPoint(x: 58, y: 8), control2: CGPoint(x: 62, y: 15))
        p.addCurve(to: CGPoint(x: 55, y: 40), control1: CGPoint(x: 64, y: 34), control2: CGPoint(x: 60, y: 40))
        p.addCurve(to: CGPoint(x: 43, y: 34), control1: CGPoint(x: 50, y: 40), control2: CGPoint(x: 47, y: 34))
        p.addLine(to: CGPoint(x: 21, y: 34))
        p.addCurve(to: CGPoint(x: 9, y: 40), control1: CGPoint(x: 17, y: 34), control2: CGPoint(x: 14, y: 40))
        p.addCurve(to: CGPoint(x: 1, y: 25), control1: CGPoint(x: 4, y: 40), control2: CGPoint(x: 0, y: 34))
        p.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: 2, y: 15), control2: CGPoint(x: 6, y: 8))
        p.closeSubpath()
        return p
    }

    /// 系统手柄（稿里 ips，viewBox 64×44）：PlayStation 带上面一条触控板；Xbox 去掉触控板、中间一颗绿色导引键（草稿，稿里没有）
    private static func pad(_ c: inout GraphicsContext, body color: Color, touchpad: Bool, guide: Color?) {
        let p = padPath()
        c.fill(p, with: .color(color))
        let dark = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        if touchpad { c.fill(Path(CGRect(x: 22, y: 8, width: 20, height: 9)), with: .color(Color(red: 0x2b / 255, green: 0x2b / 255, blue: 0x2b / 255))) }
        if let guide { c.fill(Path(ellipseIn: CGRect(x: 28.5, y: 12.5, width: 7, height: 7)), with: .color(guide)) }
        c.fill(Path(ellipseIn: CGRect(x: 44.4, y: 17.4, width: 5.2, height: 5.2)), with: .color(dark))
        c.fill(Path(ellipseIn: CGRect(x: 49.4, y: 22.4, width: 5.2, height: 5.2)), with: .color(dark))
        var plus = Path()
        plus.move(to: CGPoint(x: 14, y: 23)); plus.addLine(to: CGPoint(x: 23, y: 23))
        plus.move(to: CGPoint(x: 18.5, y: 18.5)); plus.addLine(to: CGPoint(x: 18.5, y: 27.5))
        c.stroke(plus, with: .color(dark), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// 还不知道型号：虚线手柄轮廓（#520 讨论 定，取代稿里的两只虚线 Joy-Con iq）；形状同系统手柄图
    private static func unknown(_ c: inout GraphicsContext) {
        let gray = Color(red: 0x8a / 255, green: 0x85 / 255, blue: 0x7e / 255)
        c.stroke(padPath(), with: .color(gray), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [3.5, 3]))
    }

    /// 键盘（分配成一位玩家时，#520 E；稿里没有，同 Pro 图的米色机身 + 深色键）：三排键 + 空格
    private static func keyboardGlyph(_ c: inout GraphicsContext) {
        let body = Color(red: 0xe8 / 255, green: 0xe3 / 255, blue: 0xda / 255), key = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        c.fill(Path(roundedRect: CGRect(x: 2, y: 9, width: 60, height: 28), cornerRadius: 5), with: .color(body))
        for row in 0..<3 {
            let count = row == 1 ? 7 : 8, inset: CGFloat = row == 1 ? 9.5 : 7
            for i in 0..<count {
                c.fill(Path(roundedRect: CGRect(x: inset + CGFloat(i) * 6.4, y: 13 + CGFloat(row) * 5.6, width: 4.4, height: 3.6), cornerRadius: 1), with: .color(key))
            }
        }
        c.fill(Path(roundedRect: CGRect(x: 18, y: 30, width: 28, height: 3.6), cornerRadius: 1.2), with: .color(key))
    }

    /// 手机（预留，见 Glyph.mobile）：一般直立手机外形——米色机身、深色屏幕、上方听筒、下方横条（viewBox 64×44 中间）
    private static func mobileGlyph(_ c: inout GraphicsContext) {
        let body = Color(red: 0xe8 / 255, green: 0xe3 / 255, blue: 0xda / 255), dark = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        // 横拿（当手柄用的握法）：机身 46×22，屏幕居中，两端各一条听筒 / 底边
        c.fill(Path(roundedRect: CGRect(x: 9, y: 11, width: 46, height: 22), cornerRadius: 5), with: .color(body))
        c.fill(Path(roundedRect: CGRect(x: 14, y: 13.5, width: 36, height: 17), cornerRadius: 1.5), with: .color(dark))
        var bars = Path()
        bars.move(to: CGPoint(x: 11.6, y: 19)); bars.addLine(to: CGPoint(x: 11.6, y: 25))
        bars.move(to: CGPoint(x: 52.4, y: 18)); bars.addLine(to: CGPoint(x: 52.4, y: 26))
        c.stroke(bars, with: .color(dark), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    /// Switch Pro / Switch 2 Pro（同一个外形，viewBox 64×44）：深色机身、左摇杆偏上、右摇杆偏下、右上 ABXY、左下方向键。
    ///   一代 Pro：炭黑机身、灰色键；Switch 2 Pro：同 Joy-Con 2 的深灰机身，两根摇杆圈用 Joy-Con 2 的左蓝 / 右红
    private static func proPad(_ c: inout GraphicsContext, switch2: Bool) {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 6)); p.addLine(to: CGPoint(x: 50, y: 6))
        p.addCurve(to: CGPoint(x: 63, y: 24), control1: CGPoint(x: 58, y: 6), control2: CGPoint(x: 62, y: 14))
        p.addCurve(to: CGPoint(x: 55, y: 40), control1: CGPoint(x: 64, y: 33), control2: CGPoint(x: 61, y: 40))
        p.addCurve(to: CGPoint(x: 44, y: 34), control1: CGPoint(x: 50, y: 40), control2: CGPoint(x: 48, y: 34))
        p.addLine(to: CGPoint(x: 20, y: 34))
        p.addCurve(to: CGPoint(x: 9, y: 40), control1: CGPoint(x: 16, y: 34), control2: CGPoint(x: 14, y: 40))
        p.addCurve(to: CGPoint(x: 1, y: 24), control1: CGPoint(x: 3, y: 40), control2: CGPoint(x: 0, y: 33))
        p.addCurve(to: CGPoint(x: 14, y: 6), control1: CGPoint(x: 2, y: 14), control2: CGPoint(x: 6, y: 6))
        p.closeSubpath()
        let body = switch2 ? shell : Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x27 / 255)
        c.fill(p, with: .color(body))
        c.stroke(p, with: .color(shellEdge), lineWidth: 1)
        // 摇杆：左上、右下
        for (center, accent) in [(CGPoint(x: 15, y: 17), leftAccent), (CGPoint(x: 42, y: 27), rightAccent)] {
            let r = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            c.fill(Path(ellipseIn: r), with: .color(stickFill))
            c.stroke(Path(ellipseIn: r), with: .color(switch2 ? accent : shellEdge), lineWidth: 1.6)
        }
        // ABXY（右上菱形）
        for (dx, dy) in [(0.0, -3.8), (3.8, 0.0), (0.0, 3.8), (-3.8, 0.0)] {
            c.fill(Path(ellipseIn: CGRect(x: 49 + dx - 1.8, y: 16.5 + dy - 1.8, width: 3.6, height: 3.6)), with: .color(key))
        }
        // 方向键（左下十字）
        var dpad = Path()
        dpad.move(to: CGPoint(x: 19, y: 27.5)); dpad.addLine(to: CGPoint(x: 26, y: 27.5))
        dpad.move(to: CGPoint(x: 22.5, y: 24)); dpad.addLine(to: CGPoint(x: 22.5, y: 31))
        c.stroke(dpad, with: .color(key), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        // − / +
        var signs = Path()
        signs.move(to: CGPoint(x: 26, y: 13)); signs.addLine(to: CGPoint(x: 29, y: 13))
        signs.move(to: CGPoint(x: 35, y: 13)); signs.addLine(to: CGPoint(x: 38, y: 13))
        signs.move(to: CGPoint(x: 36.5, y: 11.5)); signs.addLine(to: CGPoint(x: 36.5, y: 14.5))
        c.stroke(signs, with: .color(key), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    /// 缺省手柄（认不出 / 第三方）：白色圆润机身、方向十字 + 两颗键
    private static func generic(_ c: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 6)); p.addLine(to: CGPoint(x: 50, y: 6))
        p.addCurve(to: CGPoint(x: 63, y: 24), control1: CGPoint(x: 58, y: 6), control2: CGPoint(x: 62, y: 14))
        p.addCurve(to: CGPoint(x: 55, y: 40), control1: CGPoint(x: 64, y: 33), control2: CGPoint(x: 61, y: 40))
        p.addCurve(to: CGPoint(x: 44, y: 34), control1: CGPoint(x: 50, y: 40), control2: CGPoint(x: 48, y: 34))
        p.addLine(to: CGPoint(x: 20, y: 34))
        p.addCurve(to: CGPoint(x: 9, y: 40), control1: CGPoint(x: 16, y: 34), control2: CGPoint(x: 14, y: 40))
        p.addCurve(to: CGPoint(x: 1, y: 24), control1: CGPoint(x: 3, y: 40), control2: CGPoint(x: 0, y: 33))
        p.addCurve(to: CGPoint(x: 14, y: 6), control1: CGPoint(x: 2, y: 14), control2: CGPoint(x: 6, y: 6))
        p.closeSubpath()
        c.fill(p, with: .color(Color(red: 0xe8 / 255, green: 0xe3 / 255, blue: 0xda / 255)))
        let dark = Color(red: 0x2a / 255, green: 0x28 / 255, blue: 0x26 / 255)
        c.fill(Path(ellipseIn: CGRect(x: 43, y: 15, width: 6, height: 6)), with: .color(dark))
        c.fill(Path(ellipseIn: CGRect(x: 49, y: 21, width: 6, height: 6)), with: .color(dark))
        var plus = Path()
        plus.move(to: CGPoint(x: 15, y: 21)); plus.addLine(to: CGPoint(x: 25, y: 21))
        plus.move(to: CGPoint(x: 20, y: 16)); plus.addLine(to: CGPoint(x: 20, y: 26))
        c.stroke(plus, with: .color(dark), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }
}
