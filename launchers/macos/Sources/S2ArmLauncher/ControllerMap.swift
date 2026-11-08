import SwiftUI

/// Switch positions, not Xbox lettering. A is right, B bottom, X top, Y left.
enum ControllerMapLayout {
    static let face = [["", "X", ""], ["Y", "", "A"], ["", "B", ""]]
    static let dpad = [["", "UP", ""], ["LEFT", "", "RIGHT"], ["", "DOWN", ""]]
    static let leftStick = [["", "LS_UP", ""], ["LS_LEFT", "LS", "LS_RIGHT"], ["", "LS_DOWN", ""]]
    static let rightStick = [["", "RS_UP", ""], ["RS_LEFT", "RS", "RS_RIGHT"], ["", "RS_DOWN", ""]]
    static let targets = ["L", "ZL", "R", "ZR", "MINUS", "PLUS"] + (face + dpad + leftStick + rightStick).flatMap { $0 }.filter { !$0.isEmpty }
}

enum JoyConGeometry {
    // Nintendo's first-generation Joy-Con specification: H102 × W35.9 mm.
    // https://www.nintendo.com/jp/hardware/switch/modal/specs/joy-con.html
    static let heightMM: CGFloat = 102
    static let widthMM: CGFloat = 35.9
    static let height: CGFloat = 414
    static let width: CGFloat = height * widthMM / heightMM
    // Front-view anchors are calibrated to Nintendo support's img/joycon/img02.jpg,
    // not factory CAD measurements. Keep all circular controls isotropic.
    static let upperY: CGFloat = height * 0.255
    static let lowerY: CGFloat = height * 0.535
    static let auxiliaryY: CGFloat = height * 0.72
    static let clusterStep: CGFloat = height * 0.075
    static let buttonDiameter: CGFloat = height * 0.076
    static let stickDiameter: CGFloat = height * 0.156
}

/// Original vector outline for the paired Joy-Con layout, with a flat inner rail.
/// Interactive controls are separate native buttons, not a flattened screenshot.
struct JoyConShell: Shape {
    var right = false
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, radius = rect.width * 0.61
        var p = Path()
        p.move(to: CGPoint(x: w - 9, y: 0))
        p.addLine(to: CGPoint(x: radius, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: radius), control1: CGPoint(x: radius*0.45, y: 0), control2: CGPoint(x: 0, y: radius*0.45))
        p.addLine(to: CGPoint(x: 0, y: h - radius))
        p.addCurve(to: CGPoint(x: radius, y: h), control1: CGPoint(x: 0, y: h - radius*0.45), control2: CGPoint(x: radius*0.45, y: h))
        p.addLine(to: CGPoint(x: w - 9, y: h))
        p.addQuadCurve(to: CGPoint(x: w, y: h - 9), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w, y: 9))
        p.addQuadCurve(to: CGPoint(x: w - 9, y: 0), control: CGPoint(x: w, y: 0))
        p.closeSubpath()
        return right ? p.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)) : p
    }
}

extension InputConfig {
    func shortBinding(_ target: String) -> String {
        if let key = keyboard[target] { return keyName(key) }
        if let button = mouse[target] { return mouseButtonName(button) }
        return gamepad[target] == nil ? L("未绑定") : L("手柄")
    }
    var conflictingTargets: Set<String> {
        var result = Set<String>()
        for target in Self.targets {
            if let key = keyboard[target], keyboard.filter({ $0.value == key }).count > 1 { result.insert(target) }
            if let button = mouse[target], mouse.filter({ $0.value == button }).count > 1 { result.insert(target) }
            if let button = gamepad[target], gamepad.filter({ $0.value == button }).count > 1 { result.insert(target) }
        }
        return result
    }
    mutating func restoreTarget(_ target: String, from original: InputConfig) {
        keyboard[target] = original.keyboard[target]; mouse[target] = original.mouse[target]; gamepad[target] = original.gamepad[target]
    }
}

func mouseButtonName(_ code: Int) -> String {
    let names = [L("左键"), L("右键"), L("中键"), L("侧键 1"), L("侧键 2")]
    return names.indices.contains(code) ? names[code] : L("未绑定")
}

struct ControllerMapView: View {
    let config: InputConfig
    @Binding var selected: String
    var recording: String? = nil
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(L("Switch 按键位置"), systemImage: "gamecontroller")
                    .font(.headline)
                Spacer()
                Text(L("点击一个按键")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 58) {
                joycon(right: false)
                joycon(right: true)
            }.frame(maxWidth: .infinity)
            Text(L("摇杆外侧箭头表示推杆方向。HOME / 截图键仅作示意。")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxHeight:.infinity,alignment:.topLeading).padding(WorkspaceLayout.cardInset).switchSettingsPanel()
    }

    func joycon(right: Bool) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) { key(right ? "R" : "ZL", wide: true); key(right ? "ZR" : "L", wide: true) }
            ZStack {
                JoyConShell(right: right)
                    .fill(right ? SwitchControlsPalette.red : SwitchControlsPalette.blue)
                    .overlay(JoyConShell(right: right).stroke(.black.opacity(0.20), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.13), radius: 7, y: 5)
                RoundedRectangle(cornerRadius: 2).fill(SwitchControlsPalette.ink.opacity(0.28)).frame(width: 4, height: JoyConGeometry.height*0.94).position(x: right ? 3 : JoyConGeometry.width-3, y: JoyConGeometry.height*0.50).accessibilityHidden(true)
                key(right ? "PLUS" : "MINUS", auxiliary: true).position(x: JoyConGeometry.width*(right ? 0.22 : 0.78), y: JoyConGeometry.height*0.10)
                if right {
                    cluster(ControllerMapLayout.face).position(x: JoyConGeometry.width/2, y: JoyConGeometry.upperY)
                    stick(right: true).position(x: JoyConGeometry.width/2, y: JoyConGeometry.lowerY)
                } else {
                    stick(right: false).position(x: JoyConGeometry.width/2, y: JoyConGeometry.upperY)
                    cluster(ControllerMapLayout.dpad).position(x: JoyConGeometry.width/2, y: JoyConGeometry.lowerY)
                }
                Image(systemName: right ? "house.fill" : "record.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    .frame(width: 23, height: 23).background(SwitchControlsPalette.ink.opacity(0.84), in: right ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
                    .position(x: JoyConGeometry.width*(right ? 0.35 : 0.65), y: JoyConGeometry.auxiliaryY).accessibilityHidden(true)
            }.frame(width: JoyConGeometry.width, height: JoyConGeometry.height)
        }
    }

    func cluster(_ rows: [[String]]) -> some View {
        ZStack {
            ForEach(rows.indices, id: \.self) { row in
                ForEach(rows[row].indices, id: \.self) { column in
                    let target = rows[row][column]
                    if !target.isEmpty { key(target).position(x: 70 + CGFloat(column-1)*JoyConGeometry.clusterStep, y: 70 + CGFloat(row-1)*JoyConGeometry.clusterStep) }
                }
            }
        }.frame(width: 140, height: 140)
    }

    func stick(right: Bool) -> some View {
        let prefix = right ? "RS" : "LS"
        return ZStack {
            key(prefix, onStick: true).position(x: 75, y: 75)
            stickDirection(prefix + "_UP", symbol: "arrow.up").position(x: 75, y: 29)
            stickDirection(prefix + "_DOWN", symbol: "arrow.down").position(x: 75, y: 121)
            stickDirection(prefix + "_LEFT", symbol: "arrow.left").position(x: 29, y: 75)
            stickDirection(prefix + "_RIGHT", symbol: "arrow.right").position(x: 121, y: 75)
        }.frame(width: 150, height: 150)
    }

    func stickDirection(_ target: String, symbol: String) -> some View {
        let active = selected == target
        return Button { selected = target; onSelect?(target) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if selected == target { Text(config.shortBinding(target)).font(.system(size: 9, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7) }
            }.frame(width: 42, height: 38)
                .foregroundStyle(config.conflictingTargets.contains(target) ? .red : SwitchControlsPalette.ink)
                .background(active ? .white.opacity(0.95) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? SwitchControlsPalette.focus : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel(L("选择按键 {0}").replacingOccurrences(of: "{0}", with: targetName(target)))
            .accessibilityValue(config.shortBinding(target)).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    func key(_ target: String, wide: Bool = false, onStick: Bool = false, auxiliary: Bool = false) -> some View {
        let active = selected == target
        let conflict = config.conflictingTargets.contains(target)
        let symbol: String? = ["UP":"arrow.up", "DOWN":"arrow.down", "LEFT":"arrow.left", "RIGHT":"arrow.right",
                               "LS_UP":"arrow.up", "LS_DOWN":"arrow.down", "LS_LEFT":"arrow.left", "LS_RIGHT":"arrow.right",
                               "RS_UP":"arrow.up", "RS_DOWN":"arrow.down", "RS_LEFT":"arrow.left", "RS_RIGHT":"arrow.right"][target]
        let text = ["MINUS":"−", "PLUS":"+", "LS":"L3", "RS":"R3"][target] ?? target
        let diameter = onStick ? JoyConGeometry.stickDiameter : auxiliary ? 20 : JoyConGeometry.buttonDiameter
        return Button {
            selected = target; onSelect?(target)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                    else { Text(text).font(.system(size: onStick ? 13 : auxiliary ? 15 : 12, weight: .semibold, design: .rounded)) }
                }
                .frame(width: wide ? 66 : diameter, height: wide ? 30 : diameter)
                .foregroundStyle(.white)
                .background(SwitchControlsPalette.ink, in: RoundedRectangle(cornerRadius: wide ? 8 : diameter/2))
                .overlay(RoundedRectangle(cornerRadius: wide ? 8 : diameter/2).strokeBorder(conflict ? .red : active ? SwitchControlsPalette.focusRing : .black.opacity(0.30), lineWidth: active || conflict ? 3 : 1))
                .shadow(color: .black.opacity(onStick ? 0.25 : 0.08), radius: onStick ? 3 : 1, y: onStick ? 3 : 1)
                if wide { Text(recording == target ? "…" : config.shortBinding(target))
                    .font(.system(size: 10, weight: active ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(conflict ? .red : onStick ? .white.opacity(0.9) : wide ? .secondary : SwitchControlsPalette.ink)
                    .lineLimit(1).minimumScaleFactor(0.75).frame(width: 68) }
            }.frame(width: wide ? 68 : max(44,diameter), height: wide ? 46 : max(44,diameter))
        }.buttonStyle(.plain)
            .accessibilityLabel(L("选择按键 {0}").replacingOccurrences(of: "{0}", with: targetName(target)))
            .accessibilityValue(config.shortBinding(target))
            .accessibilityAddTraits(active ? [.isSelected] : [])
            .help(targetName(target) + " · " + config.shortBinding(target))
    }
}

struct ReadOnlyBindingPanel: View {
    let config: InputConfig
    let target: String
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("游戏中的提示")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(targetName(target)).font(.title2.bold())
            Divider()
            item(L("键盘"), icon: "keyboard", value: keyName(config.keyboard[target]))
            item(L("鼠标"), icon: "computermouse", value: config.mouse[target].map(mouseButtonName) ?? L("未绑定"))
            item(L("手柄物理位置"), icon: "gamecontroller", value: config.gamepad[target].map(padName) ?? L("未绑定"))
            Spacer(minLength: 8)
            Label(L("具体功能以游戏提示为准"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }.padding(WorkspaceLayout.cardInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).switchSettingsPanel()
    }
    func item(_ label: String, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.title3, design: .monospaced)).fontWeight(.medium) }
    }
}
