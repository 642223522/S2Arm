// S2Arm（不是上游文件）：模拟手柄（本地开发 / 自测用）。App 菜单「模擬手把…」打开一个浮动面板：加几只假的一代 Joy-Con / Joy-Con 2（各自上色）、
//   Switch Pro / Switch 2 Pro / PS5 / Xbox，连上 / 断开 / 按 SL + SR、L / R 都走真的分配逻辑（PlayerAssignment），用来看图示动态上色、
//   缺省色（第三方不报颜色），以及一代 Joy-Con 自动合并 / 拆开跟 Joy-Con 2 是不是同一套体验，不用真的凑齐好几套手柄。
//   怎么接进去（同真机）：
//   · 一代：每只是一台按设备看到的 HID（SystemControllers.gen1 / gen1Colors）；同一套左右都连着时，系统那边另有一个合成的
//     「Joy-Con (L/R)」手柄，只连一只时是「Joy-Con (L)」/「(R)」（SystemControllers.pads）。按键：L + R 同按 = 系统那一位登记 + 两只 HID 各报肩键；
//     SL + SR / L / R = 那只 HID 报手势（NS2LauncherController.registerGen1）
//   · Joy-Con 2 / Switch 2 Pro：每只是连接程序报的一台（NS2LauncherController.allDevices），同一套在同一组（传输层缺省两只拼成一位）；按键走 receiveAssign
//   · Switch Pro / PS5 / Xbox：系统手柄（SystemControllers.pads），L1 + R1 = registerSystem
//   加「左」/「右」时，同款有一套只差这一边的就补进那一套（同真机：另一只接上就配成一对），否则自己一套。
//   开关同「模擬更新」：偏好 S2AControllerSimulate 开着、且是没有更新源的构建（本地 / 自测拷贝）才有；带 SUFeedURL 的发行版不出这个菜单、也不会有模拟手柄。
//   注意：模拟的手柄会写进给游戏的顺序表（pad-order.json），开着模拟手柄进游戏，玩家位会对不上——测完「全部清除」
import AppKit
import SwiftUI
import NXCore

/// 面板文案：繁中 / 简中 / 英文三种（开发工具，不进全 App 的 l10n 文件）；跟 App 的界面语言（appLanguage），其他语言用英文
enum SimText {
    static func pick(_ hant: String, _ hans: String, _ en: String) -> String {
        let code = (Lang.find(UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .device()).code
        return code.hasPrefix("zh-Hant") ? hant : code.hasPrefix("zh") ? hans : en
    }
}

@MainActor final class ControllerColorSimulator: ObservableObject {
    static let shared = ControllerColorSimulator()

    /// 开关（同「模擬更新」的 S2AUpdateSimulate）：`defaults write <bundle id> S2AControllerSimulate -bool YES` 打开、`-bool NO` 关掉，重开 App 生效。
    ///   带 SUFeedURL 的发行版即使开着也没有
    static let enabledKey = "S2AControllerSimulate"
    nonisolated static func isAllowed(preference: Bool, info: [String: Any]?) -> Bool { preference && ((info?["SUFeedURL"] as? String) ?? "").isEmpty }
    /// 启动时定一次（中途改开关要重开 App，免得分配里留着模拟手柄）
    static let allowed = isAllowed(preference: UserDefaults.standard.bool(forKey: enabledKey), info: Bundle.main.infoDictionary)

    /// 模拟的手柄款式：两种 Joy-Con 分左右只；其余是整只（一台）
    enum Kind: String, CaseIterable {
        case joyCon1 = "一代", joyCon2 = "Joy-Con 2", switchPro = "Switch Pro", switch2Pro = "Switch 2 Pro", ps5 = "PS5", xbox = "Xbox"
        var isJoyCon: Bool { self == .joyCon1 || self == .joyCon2 }
        var title: String { self == .joyCon1 ? SimText.pick("一代", "一代", "Gen-1") : rawValue }
        static let whole: [Kind] = [.switchPro, .switch2Pro, .ps5, .xbox]
        /// 走 GameController 的系统手柄名（同真机 vendorName）；Switch 2 系列走连接程序，没有
        var systemName: String? {
            switch self {
            case .switchPro: return "Pro Controller"
            case .ps5: return "DualSense Wireless Controller"
            case .xbox: return "Xbox Wireless Controller"
            default: return nil
            }
        }
        var family: SystemControllers.Family {
            switch self { case .switchPro: return .nintendoPro; case .ps5: return .playstation; case .xbox: return .xbox; default: return .other }
        }
    }
    struct Preset: Hashable {
        let hant: String, hans: String, en: String
        let tint: ControllerTint?   // nil = 不报颜色（第三方），照缺省色
        init(_ hant: String, _ hans: String, _ en: String, tint: ControllerTint?) { self.hant = hant; self.hans = hans; self.en = en; self.tint = tint }
        var name: String { SimText.pick(hant, hans, en) }
    }
    /// 一只（Joy-Con 的一边，或整只手柄）：present = 加过、还没移除；connected = 现在连着
    struct Half: Equatable {
        let id: String
        var preset: Preset
        var present: Bool
        var connected: Bool
    }
    /// 一套：Joy-Con 一左一右（可能只有一边）；整只手柄只用 left 那一半
    final class Kit: Identifiable {
        let id: Int
        let kind: Kind
        var left: Half, right: Half
        let systemToken = NSObject()   // 系统手柄的身份（SystemControllers.Pad.id）
        init(id: Int, kind: Kind, left: Half, right: Half) { self.id = id; self.kind = kind; self.left = left; self.right = right }
        var gen2: Bool { kind == .joyCon2 }
        func half(_ isLeft: Bool) -> Half { isLeft ? left : right }
        /// 系统那边的手柄名：一代两只都连着 = 合成的一个；整只的系统手柄连着就有；断开 / Switch 2 系列 = 没有
        var systemName: String? {
            if let name = kind.systemName { return left.connected ? name : nil }
            guard kind == .joyCon1 else { return nil }
            switch (left.connected, right.connected) {
            case (true, true): return "Joy-Con (L/R)"
            case (true, false): return "Joy-Con (L)"
            case (false, true): return "Joy-Con (R)"
            default: return nil
            }
        }
        var systemFamily: SystemControllers.Family {
            guard kind == .joyCon1 else { return kind.family }
            return left.connected && right.connected ? .gen1Pair : left.connected ? .gen1Left : .gen1Right
        }
    }
    /// 面板上的一行 = 一只
    struct Row: Identifiable {
        let kit: Kit
        let isLeft: Bool
        var half: Half { kit.half(isLeft) }
        var id: String { half.id }
        var title: String {
            guard kit.kind.isJoyCon else { return kit.kind.title }
            let side = isLeft ? SimText.pick("左", "左", "L") : SimText.pick("右", "右", "R")
            return "\(kit.kind.title) \(side) · \(half.preset.name)"
        }
    }

    /// 一代 Joy-Con 的出厂色（机身 / 按键，SPI 0x6050 的格式）
    static let gen1Presets: [Preset] = [
        Preset("電光藍", "电光蓝", "Neon Blue", tint: ControllerTint(body: 0x0ab9e6, buttons: 0x001e1e)),
        Preset("電光紅", "电光红", "Neon Red", tint: ControllerTint(body: 0xff3c28, buttons: 0x1e0a0a)),
        Preset("灰", "灰", "Grey", tint: ControllerTint(body: 0x828282, buttons: 0x0f0f0f)),
        Preset("電光黃", "电光黄", "Neon Yellow", tint: ControllerTint(body: 0xe6ff00, buttons: 0x142800)),
        Preset("電光綠", "电光绿", "Neon Green", tint: ControllerTint(body: 0x1edc00, buttons: 0x002800)),
        Preset("電光粉", "电光粉", "Neon Pink", tint: ControllerTint(body: 0xff3278, buttons: 0x28001e)),
        Preset("電光紫", "电光紫", "Neon Purple", tint: ControllerTint(body: 0xb400e6, buttons: 0x140014)),
        Preset("電光橙", "电光橙", "Neon Orange", tint: ControllerTint(body: 0xfaa005, buttons: 0x0f0a00)),
        Preset("第三方", "第三方", "Third-party", tint: nil),
    ]
    /// Joy-Con 2 的边条色（机身都是深灰，图示只换边条与摇杆圈）
    static let gen2Presets: [Preset] = [
        Preset("淺藍", "浅蓝", "Light Blue", tint: ControllerTint(body: 0x41b8e8)),
        Preset("紅", "红", "Red", tint: ControllerTint(body: 0xef5a5a)),
        Preset("淺紫", "浅紫", "Light Purple", tint: ControllerTint(body: 0xb8a6e8)),
        Preset("淺綠", "浅绿", "Light Green", tint: ControllerTint(body: 0x9ee6a0)),
        Preset("黃", "黄", "Yellow", tint: ControllerTint(body: 0xf2d230)),
        Preset("第三方", "第三方", "Third-party", tint: nil),
    ]
    static func presets(_ kind: Kind) -> [Preset] { kind == .joyCon2 ? gen2Presets : gen1Presets }

    @Published private(set) var kits: [Kit] = []
    /// 「左」「右」按钮旁边选的颜色（按款式、左右各记一个）
    @Published var colors: [String: Preset] = [
        "joyCon1-L": gen1Presets[0], "joyCon1-R": gen1Presets[1], "joyCon2-L": gen2Presets[0], "joyCon2-R": gen2Presets[1],
    ]
    func color(_ kind: Kind, left: Bool) -> Preset { colors["\(kind)-\(left ? "L" : "R")"] ?? Self.presets(kind)[0] }
    func setColor(_ kind: Kind, left: Bool, _ preset: Preset) { colors["\(kind)-\(left ? "L" : "R")"] = preset }
    /// 勾选的几只（「一起按 L + R」用）
    @Published var selected: Set<String> = []
    /// 按键送去哪（LauncherView 接上）
    weak var controller: NS2LauncherController?
    private var nextID = 1

    var rows: [Row] {
        kits.flatMap { k in [Row(kit: k, isLeft: true), Row(kit: k, isLeft: false)].filter(\.half.present) }
    }

    // —— 给 SystemControllers / NS2LauncherController 读的 ——
    var gen1Devices: [PlayerAssignment.Gen1Device] {
        kits.filter { $0.kind == .joyCon1 }.flatMap { k in
            [k.left.connected ? PlayerAssignment.Gen1Device(id: k.left.id, side: 0) : nil, k.right.connected ? .init(id: k.right.id, side: 1) : nil].compactMap { $0 }
        }
    }
    var gen1Colors: [String: ControllerTint] {
        var out: [String: ControllerTint] = [:]
        for k in kits where k.kind == .joyCon1 { out[k.left.id] = k.left.preset.tint; out[k.right.id] = k.right.preset.tint }
        return out
    }
    func systemPads() -> [SystemControllers.Pad] {
        kits.compactMap { k in
            guard let name = k.systemName else { return nil }
            return SystemControllers.Pad(id: ObjectIdentifier(k.systemToken), name: name, family: k.systemFamily)
        }
    }
    /// 系统合成那一位的颜色（按 Pad.id 认）
    func systemColors(_ id: ObjectIdentifier) -> ControllerColors? {
        guard let k = kits.first(where: { ObjectIdentifier($0.systemToken) == id }), k.kind == .joyCon1 else { return nil }
        return ControllerColors(left: k.left.connected ? k.left.preset.tint : nil, right: k.right.connected ? k.right.preset.tint : nil)
    }
    /// Joy-Con 2 / Switch 2 Pro：每套一组（组号从 100 起，不跟真的连接程序撞）
    var ns2Devices: [PlayerAssignment.Device] {
        kits.flatMap { k -> [PlayerAssignment.Device] in
            switch k.kind {
            case .joyCon2:
                return [k.left.connected ? PlayerAssignment.Device(id: k.left.id, kind: 2, group: 100 + k.id) : nil,
                        k.right.connected ? PlayerAssignment.Device(id: k.right.id, kind: 3, group: 100 + k.id) : nil].compactMap { $0 }
            case .switch2Pro: return k.left.connected ? [PlayerAssignment.Device(id: k.left.id, kind: 1, group: 100 + k.id)] : []
            default: return []
            }
        }
    }
    /// 两只都连着的 Joy-Con 2 组（传输层缺省拼成一位）
    var ns2MergedGroups: Set<Int> { Set(kits.filter { $0.gen2 && $0.left.connected && $0.right.connected }.map { 100 + $0.id }) }
    func ns2Tint(_ id: String) -> ControllerTint? {
        for k in kits where k.gen2 { if k.left.id == id { return k.left.preset.tint }; if k.right.id == id { return k.right.preset.tint } }
        return nil
    }

    // —— 面板动作 ——
    /// 加一只 Joy-Con：同款有一套只差这一边（另一边连着）就补进那一套，否则自己一套
    func addJoyCon(_ kind: Kind, left: Bool) {
        let preset = color(kind, left: left)
        if let k = kits.first(where: { $0.kind == kind && !$0.half(left).present && $0.half(!left).connected }) {
            let fresh = Half(id: k.half(left).id, preset: preset, present: true, connected: true)
            if left { k.left = fresh } else { k.right = fresh }
        } else {
            let n = nextID; nextID += 1
            let prefix = "sim-\(kind)-\(n)"
            kits.append(Kit(id: n, kind: kind,
                            left: Half(id: prefix + "-L", preset: preset, present: left, connected: left),
                            right: Half(id: prefix + "-R", preset: preset, present: !left, connected: !left)))
        }
        changed()
    }
    func addWhole(_ kind: Kind) {
        let n = nextID; nextID += 1
        let none = Preset("", "", "", tint: nil)
        kits.append(Kit(id: n, kind: kind, left: Half(id: "sim-\(kind)-\(n)", preset: none, present: true, connected: true),
                        right: Half(id: "sim-\(kind)-\(n)-x", preset: none, present: false, connected: false)))
        changed()
    }
    func toggleConnected(_ row: Row) {
        if row.isLeft { row.kit.left.connected.toggle() } else { row.kit.right.connected.toggle() }
        changed()
    }
    func remove(_ row: Row) {
        if row.isLeft { row.kit.left.present = false; row.kit.left.connected = false } else { row.kit.right.present = false; row.kit.right.connected = false }
        selected.remove(row.id)
        kits.removeAll { !$0.left.present && !$0.right.present }
        changed()
    }
    func disconnectAll() {
        for k in kits { k.left.connected = false; k.right.connected = false }
        changed()
    }
    func clear() { kits = []; selected = []; changed() }

    /// 按键（分配玩家开着时才有作用，同真机）：gesture 2 = SL + SR、3 = 肩键 L / R；整只手柄 = 同按 L1 + R1 登记
    func press(_ row: Row, gesture: Int) {
        let half = row.half
        guard half.connected, let controller else { return }
        switch row.kit.kind {
        case .joyCon2: controller.receiveAssign(["id": half.id, "kind": row.isLeft ? 2 : 3, "gesture": gesture])
        case .joyCon1: controller.registerGen1(id: half.id, side: row.isLeft ? 0 : 1, gesture: gesture)
        case .switch2Pro: controller.receiveAssign(["id": half.id, "kind": 1, "gesture": 1])
        default:
            if let name = row.kit.systemName, let index = systemsIndex(name: name, kit: row.kit) { controller.registerSystem(name: name, index: index) }
        }
    }
    /// 按键面板上的键（显示字；方向用箭头）：左只 / 右只 / 整只各一组
    func keys(for row: Row) -> [String] {
        if !row.kit.kind.isJoyCon { return ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "−", "+", "↑", "↓", "←", "→", "Home"] }
        return row.isLeft ? ["↑", "↓", "←", "→", "L", "ZL", "−", "Capture", "LS", "SL", "SR"]
                          : ["A", "B", "X", "Y", "R", "ZR", "+", "Home", "RS", "SL", "SR"]
    }
    /// 按一个键：玩家那一行亮出按了哪个键（同真机认手柄）；分配中 L / R（肩键）照真机算登记手势
    func pressKey(_ row: Row, _ key: String) {
        guard row.half.connected, let controller else { return }
        let arrows = ["↑": NS2LauncherController.keyUp, "↓": NS2LauncherController.keyDown, "←": NS2LauncherController.keyLeft, "→": NS2LauncherController.keyRight]
        let shown = arrows[key] ?? key
        let id = row.half.id, kit = row.kit
        let systemKey: PlayerAssignment.SystemKey? = kit.systemName.flatMap { name in systemsIndex(name: name, kit: kit).map { .init(name: name, index: $0) } }
        controller.flashPlayer(key: shown) { unit in
            switch unit {
            case let .pair(l, r), let .gen1Pair(l, r): return l == id || r == id
            case let .single(u, _), let .whole(u, _), let .gen1(u, _): return u == id
            case let .system(name, index): return systemKey == .init(name: name, index: index)
            case .keyboard: return false
            }
        }
        if kit.kind.isJoyCon, key == (row.isLeft ? "L" : "R") { press(row, gesture: 3) }
    }
    /// 勾选的两只同按 L + R（左只 L、右只 R 同一刻）：同一套一代两只都连着时，系统合成那一位也一起登记（同真机 L + R 学到这一位里是哪两只）
    var canPressSelected: Bool {
        let picked = rows.filter { selected.contains($0.id) && $0.half.connected && $0.kit.kind.isJoyCon }
        return picked.count == 2 && picked[0].kit.kind == picked[1].kit.kind && picked[0].isLeft != picked[1].isLeft
    }
    func pressSelected() {
        guard canPressSelected, let controller else { return }
        let picked = rows.filter { selected.contains($0.id) }
        if picked[0].kit === picked[1].kit, picked[0].kit.kind == .joyCon1, let name = picked[0].kit.systemName,
           let index = systemsIndex(name: name, kit: picked[0].kit) { controller.registerSystem(name: name, index: index) }
        for row in picked { press(row, gesture: 3) }
    }
    /// 系统手柄的「同名第几只」（SystemControllers.keys 同一套）：系统那边的全部手柄里，同名的排第几
    var systemPadsInOrder: () -> [SystemControllers.Pad] = { [] }
    private func systemsIndex(name: String, kit: Kit) -> Int? {
        let same = systemPadsInOrder().filter { $0.name == name }
        return same.firstIndex { $0.id == ObjectIdentifier(kit.systemToken) }
    }

    private func changed() {
        objectWillChange.send()
        DispatchQueue.main.async { [weak self] in self?.onChange.forEach { $0() } }
    }
    /// 连上 / 断开后要重对的（SystemControllers 重列手柄、NS2LauncherController 重对分配）
    var onChange: [() -> Void] = []
}

/// App 菜单：模擬手把（只在 ControllerColorSimulator.allowed 时挂）。菜单栏的菜单点一下就会收起，连续操作不方便，
///   所以菜单只放一项，打开一个浮动面板（ControllerSimulatorPanel），面板一直开着、按完不会关
struct ControllerColorSimulatorMenu: View {
    var body: some View {
        Button(SimText.pick("模擬手把", "模拟手柄", "Simulate controllers")) { ControllerSimulatorPanel.show() }
    }
}

@MainActor enum ControllerSimulatorPanel {
    private static var panel: NSPanel?
    /// 面板开着（手柄面板这时点外面不收，方便对着测）
    static var isOpen: Bool { panel?.isVisible == true }
    static func show() {
        if let panel { panel.title = SimText.pick("模擬手把", "模拟手柄", "Simulated controllers"); panel.orderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = SimText.pick("模擬手把", "模拟手柄", "Simulated controllers")
        p.isFloatingPanel = true          // 浮在启动器上面，看着手柄面板一起操作
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ControllerSimulatorPanelView())
        p.center()
        p.orderFront(nil)
        panel = p
    }
}

/// 面板：上半「加手把」（颜色在按钮旁边选、按一下就连上），下半「連著的手把」（一只一行，动作都在那一行）。间距一律 4 的倍数
struct ControllerSimulatorPanelView: View {
    @ObservedObject var sim = ControllerColorSimulator.shared
    @AppStorage("appLanguage") private var language = ""   // 换界面语言时面板跟着重画

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SimLabel(SimText.pick("加手把", "添加手柄", "Add controller"))
                addRow(.joyCon1)
                addRow(.joyCon2)
                HStack(spacing: 8) {
                    Text(SimText.pick("整支", "整只", "Full pad")).lineLimit(1).frame(width: 84, alignment: .leading)
                    ForEach(ControllerColorSimulator.Kind.whole, id: \.self) { kind in Button(kind.title) { sim.addWhole(kind) } }
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SimLabel(SimText.pick("連著的手把", "连着的手柄", "Connected"))
                    Spacer()
                    Text(SimText.pick("按鍵要「分配玩家」開著", "按键要「分配玩家」开着", "Presses count while Assign players is open")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sim.rows) { row in
                            SimRow(sim: sim, row: row)
                            if row.id != sim.rows.last?.id { Divider() }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .overlay { if sim.rows.isEmpty { Text(SimText.pick("還沒有手把", "还没有手柄", "No controllers yet")).font(.system(size: 12)).foregroundStyle(.tertiary) } }
                HStack(spacing: 8) {
                    Button(SimText.pick("一起按 L + R（已選 \(sim.selected.count) 隻）", "一起按 L + R（已选 \(sim.selected.count) 只）", "Press L + R together (\(sim.selected.count) selected)")) { sim.pressSelected() }.disabled(!sim.canPressSelected)
                    Spacer()
                    Button(SimText.pick("全部斷開", "全部断开", "Disconnect all")) { sim.disconnectAll() }.disabled(sim.rows.isEmpty)
                    Button(SimText.pick("全部清除", "全部清除", "Clear all")) { sim.clear() }.disabled(sim.rows.isEmpty)
                }
            }
            .padding(12)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .frame(minWidth: 400, minHeight: 320)
    }

    private func addRow(_ kind: ControllerColorSimulator.Kind) -> some View {
        HStack(spacing: 8) {
            Text(kind == .joyCon1 ? SimText.pick("一代 Joy-Con", "一代 Joy-Con", "Gen-1 Joy-Con") : "Joy-Con 2").lineLimit(1).frame(width: 84, alignment: .leading)
            colorMenu(kind, left: true)
            Button(SimText.pick("左", "左", "Left")) { sim.addJoyCon(kind, left: true) }
            colorMenu(kind, left: false).padding(.leading, 12)
            Button(SimText.pick("右", "右", "Right")) { sim.addJoyCon(kind, left: false) }
        }
    }
    /// 选单项前面的颜色点（系统选单只认图片；不当模板图，才画得出颜色）。第三方 = 空心圈
    static func swatch(_ tint: ControllerTint?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            if let tint {
                NSColor(red: CGFloat(tint.body >> 16 & 0xff) / 255, green: CGFloat(tint.body >> 8 & 0xff) / 255, blue: CGFloat(tint.body & 0xff) / 255, alpha: 1).setFill()
                dot.fill()
            } else { NSColor.secondaryLabelColor.setStroke(); dot.lineWidth = 1; dot.stroke() }
            return true
        }
        image.isTemplate = false
        return image
    }
    private func colorMenu(_ kind: ControllerColorSimulator.Kind, left: Bool) -> some View {
        let current = sim.color(kind, left: left)
        return HStack(spacing: 4) {   // 颜色点放菜单外面（无边框菜单的标题只显示字）
            SimDot(tint: current.tint)
            Menu(current.name) {
                ForEach(ControllerColorSimulator.presets(kind), id: \.self) { p in
                    Button { sim.setColor(kind, left: left, p) } label: { Label { Text(p.name) } icon: { Image(nsImage: Self.swatch(p.tint)) } }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(width: 84, alignment: .leading)   // 固定宽：颜色名长短不一，上下两行的「左」「右」才对得齐
    }
}

private struct SimLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
}

/// 颜色点：不报颜色（第三方）画空心圈
private struct SimDot: View {
    let tint: ControllerTint?
    var body: some View {
        Group {
            if let tint { Circle().fill(ControllerTint.color(tint.body)) } else { Circle().strokeBorder(Color.secondary, lineWidth: 1) }
        }
        .frame(width: 8, height: 8)
    }
}

private struct SimRow: View {
    @ObservedObject var sim: ControllerColorSimulator
    let row: ControllerColorSimulator.Row

    var body: some View {
        let connected = row.half.connected
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { sim.selected.contains(row.id) },
                                     set: { if $0 { sim.selected.insert(row.id) } else { sim.selected.remove(row.id) } }))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!row.kit.kind.isJoyCon)
                .opacity(row.kit.kind.isJoyCon ? 1 : 0)
            if row.kit.kind.isJoyCon { SimDot(tint: row.half.preset.tint) }
            else { Image(systemName: "gamecontroller").font(.system(size: 10)).frame(width: 8) }
            Text(row.title).lineLimit(1)
            Text("#\(row.kit.id)").foregroundStyle(.tertiary)
            if !connected { Text(SimText.pick("已斷開", "已断开", "Disconnected")).foregroundStyle(.tertiary) }
            Spacer(minLength: 4)
            if connected {
                if row.kit.kind.isJoyCon {
                    Button("SL+SR") { sim.press(row, gesture: 2) }
                    KeyPadButton(sim: sim, row: row)
                } else {
                    Button("L1 + R1") { sim.press(row, gesture: 1) }
                    KeyPadButton(sim: sim, row: row)   // 「按鍵」一律放在「斷開」左邊
                }
            }
            Button(connected ? SimText.pick("斷開", "断开", "Disconnect") : SimText.pick("連上", "连上", "Connect")) { sim.toggleConnected(row) }
            Button { sim.remove(row) } label: { Image(systemName: "xmark") }.help(SimText.pick("移除", "移除", "Remove"))
        }
        .foregroundStyle(connected ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// 「按鍵」：点开一块按键面板（popover），点键不会收起，能连续按；点面板外面才收
private struct KeyPadButton: View {
    @ObservedObject var sim: ControllerColorSimulator
    let row: ControllerColorSimulator.Row
    @State private var open = false
    var body: some View {
        Button(SimText.pick("按鍵", "按键", "Buttons")) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 4), count: 4), spacing: 4) {
                    ForEach(sim.keys(for: row), id: \.self) { key in
                        Button { sim.pressKey(row, key) } label: { Text(key).frame(maxWidth: .infinity) }
                    }
                }
                .controlSize(.small)
                .padding(8)
            }
    }
}
