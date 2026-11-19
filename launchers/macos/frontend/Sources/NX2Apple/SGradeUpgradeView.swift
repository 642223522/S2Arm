// S2Arm（不是上游文件）：「S 级优化升级」页（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。
//   打开即查（作业 sgradeScan，pack/jobs/sgrade.py）：逐款找原始程序（存下的 → 解包缓存 → Mac 版 → 原件），按本地补丁库报这个版本能补什么；
//   分组显示：可升级 / 没有对应补丁 / 出包时选了不打入 / 没找到原始程序（要重新出包覆盖更新）。一款都升不了 → 只给「确认」。
//   玩家点了才升（11-18 维护者：不自动运行；可批量，名字写明批量升级、有全选）：可升级的每行一个勾选框和「升级」，组标题旁「全选」，
//   页脚「批量升级所选（N 款）」；都排进后台单款升级队列逐款跑（sgradeUpgradeGame：Mac 版、有 iPhone 程序件的也一起补；线程 / 内存
//   限额在作业层），页面不关，进行中页脚显示「第 i 款 / 共 n 款」和「停止」（已做完的保留）；每款进度画在它的卡片与开始按钮上
//   （S2ArmLauncherModel+SGradeUpgrade.swift），不挡别的操作。
//   原先的「升级并安装 / 导出」两个按钮去掉：装到 iPhone / 导出某款只补那一款（11-18 维护者定），升级完照常装 / 导出就带上。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct SGradeScanGame: Identifiable, Equatable {
    let id: String, name: String, program: String, total: Int, patches: [String: Int], iphone: Bool, off: Bool, ownWiden: Bool
    /// 这款的显示版本与补丁库里「别的版本」按类的版本号（作业层 versions，只收这一版没有的类；作业层 feat/sgrade-state）
    let mine: String, available: [String: [String]]
    /// 还有没补上的段（作业层 bfPending：iPhone / Mac 包任一边要补）；全 false = 这款 S 级优化已是最新，行写「已完成」、不可点不可选。
    ///   作业层没给这个字段（旧版）当作要补
    let pending: Bool
    /// 作业层明说还缺片上读取用的着色器（bfPending 有一边 true）：没有补丁（total 0）或关了 S 级也有东西可升，进「可以升级」组（同作业层 upgradable 计数）
    let bfDue: Bool
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""; name = d["name"] as? String ?? id; program = d["program"] as? String ?? "none"
        total = (d["total"] as? NSNumber)?.intValue ?? 0; iphone = d["iphone"] as? Bool ?? false; off = d["off"] as? Bool ?? false
        ownWiden = d["ownWiden"] as? Bool ?? false   // S2Arm 通用满屏（作业层 total 已算它 +1）
        let v = d["versions"] as? [String: Any] ?? [:]
        mine = v["mine"] as? String ?? ""; available = (v["available"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String] }.filter { !$0.value.isEmpty }
        patches = (d["patches"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        bfDue = (d["bfPending"] as? [String: Any]).map { $0.values.contains { ($0 as? Bool) == true } } ?? false
        pending = d["bfPending"] == nil || bfDue
    }
    var found: Bool { program != "none" }
}

struct SGradeUpgradeView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var games: [SGradeScanGame]?
    @State private var failure: String?

    var body: some View {
        let lang = loc.lang.sharedCode
        SGradeUpgradeBody(games: games, failure: failure.map(loc.backend), zh: loc.cjkPunctuation,   // 作业层原句按界面语言显示
                          x: { BackendText.launcherText("sgrade.upgrade." + $0, language: lang) },
                          upgrade: { ids in model.upgradeSGrade(ids) },
                          close: { dismiss() },
                          upgrading: Set(model.games.map(\.id).filter(model.sgradeUpgrading)),
                          batch: model.sgradeBatch, stop: { model.stopSGrade() },
                          states: Dictionary(uniqueKeysWithValues: model.games.compactMap { g in model.sgradeState(g.id).map { (g.id, $0) } }),
                          progress: Dictionary(uniqueKeysWithValues: model.games.compactMap { g in model.sgradeProgress(g.id).map { (g.id, $0) } }))
            .task { await model.readSGradeStatus(); model.resumeSGradeWatch() }
            .task { await scan() }
    }

    private func scan() async {
        do {
            let r = try await model.saveJob("sgradeScan", gameID: "")
            games = (r["games"] as? [[String: Any]] ?? []).map(SGradeScanGame.init)
        } catch { failure = error.localizedDescription }
    }
}

/// 页面本体（不碰模型，单测离屏出图用）：games == nil 为查找中
struct SGradeUpgradeBody: View {
    let games: [SGradeScanGame]?
    let failure: String?
    let zh: Bool
    let x: (String) -> String
    /// 某一行的「升级」交出这一款，「批量升级所选」交出勾选的各款（都排进后台单款升级队列）
    let upgrade: ([String]) -> Void
    let close: () -> Void
    /// 正在升级 / 排队的款：那一行按钮写「正在升级…」、不可再点、勾选框不可选
    var upgrading: Set<String> = []
    /// 作业层队列这一批：第 index 款 / 共 count 款；nil = 没在升
    var batch: SGradeBatch? = nil
    var stop: () -> Void = {}
    /// 各款在作业层队列里的状态（queued / running / done / skipped / incomplete）与在升的进度
    var states: [String: String] = [:]
    var progress: [String: Double] = [:]
    @State private var selected: Set<String> = []
    var sImage: NSImage = SGradeCardView.sGold

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: sImage).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 34, height: 34)
                    Text(x("title")).font(LauncherTheme.TypeStyle.title)
                        .foregroundStyle(LinearGradient(colors: [SGradeCardView.goldHi, SGradeCardView.gold, SGradeCardView.rose], startPoint: .leading, endPoint: .trailing))
                    Spacer()
                }
                content
            }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.top, LauncherTheme.Space.page)
            .padding(.bottom, LauncherTheme.Space.section)
            if games != nil || failure != nil {
                LauncherSheetFooter {
                    if failure == nil, !upgrades.isEmpty {
                        if let b = batch {
                            Text(x("batchProgress").replacingOccurrences(of: "{0}", with: String(b.index)).replacingOccurrences(of: "{1}", with: String(b.count)))
                                .font(LauncherTheme.TypeStyle.detail).foregroundStyle(SGradeCardView.gold).accessibilityIdentifier("sgrade.upgrade.batchProgress")
                            Button(x("stop")) { stop() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("sgrade.upgrade.stop").fixedSize()
                        } else {
                            Button(x("batch").replacingOccurrences(of: "{0}", with: String(chosen.count))) { upgrade(chosen); selected = [] }
                                .controllerButtonStyle(LauncherPrimaryButtonStyle()).disabled(chosen.isEmpty)
                                .controllerID("sgrade.upgrade.batch").controllerShortcut(.rightTrigger).fixedSize()
                        }
                        Spacer(); closeButton
                    } else {
                        Spacer()
                        Button(x("ok")) { close() }.controllerButtonStyle(LauncherPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction).controllerID("sgrade.upgrade.ok").controllerShortcut(.rightTrigger, .back)
                    }
                }
            }
        }
        .launcherSheet(.form, height: nil)
        .accessibilityIdentifier("sgrade.upgrade")
    }

    private var upgrades: [SGradeScanGame] { (games ?? []).filter { $0.found && (($0.total > 0 && !$0.off) || $0.bfDue) } }
    /// 可升级的款（页面顺序）
    var upgradeIDs: [String] { upgrades.map(\.id) }
    /// 这一行不能点也不能勾：在升 / 排队、刚做完，或作业层说已没有要补的段（被停 / 轮到时在玩的除外，可再点）
    func locked(_ id: String) -> Bool {
        if upgrading.contains(id) || states[id] == "done" { return true }
        if states[id] == "incomplete" || states[id] == "skipped" { return false }
        return upgrades.first { $0.id == id }.map { !$0.pending } ?? false
    }
    /// 勾选了、又能升的款（页面顺序）：「批量升级所选」交出这些
    var chosen: [String] { upgradeIDs.filter { selected.contains($0) && !locked($0) } }

    @ViewBuilder private var content: some View {
        if let failure {
            Text(failure).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
        } else if let games {
            let found = games.filter(\.found)
            let yes = upgrades, off = found.filter { $0.total > 0 && $0.off && !$0.bfDue }
            let noVer = found.filter { $0.total == 0 && !$0.bfDue && !$0.available.isEmpty }, no = found.filter { $0.total == 0 && !$0.bfDue && $0.available.isEmpty }
            let missing = games.filter { !$0.found }
            if found.isEmpty {
                Text(x("nothing")).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true)
            } else if yes.isEmpty {
                LauncherReadingPane {
                    VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
                        if !no.isEmpty { Text(x("none")).font(LauncherTheme.TypeStyle.body); list(no.map { ($0.name, "") }) }
                        if !noVer.isEmpty { group(x("no.version"), noVer.map { ($0.name, versions($0)) }) }
                        if !off.isEmpty { group(x("off"), off.map { ($0.name, "") }) }
                    }
                }
            } else {
                Text(x("found").replacingOccurrences(of: "{0}", with: String(found.count))).font(.manrope(14, .medium))
                let groups = VStack(alignment: .leading, spacing: 14) {
                    upgradeGroup(yes)
                    if !noVer.isEmpty { group(x("no.version"), noVer.map { ($0.name, versions($0)) }) }
                    if !no.isEmpty { group(x("no.none"), no.map { ($0.name, "") }) }
                    if !off.isEmpty { group(x("off"), off.map { ($0.name, "") }) }
                    if !missing.isEmpty { group(x("missing"), missing.map { ($0.name, "") }) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                LauncherReadingPane { groups }
                Text(x("macNote")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(x("scanning")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary) }
        }
    }

    /// 补丁是别的版本的：每类写哪个版本（规则同设置页 SGradeStateText.pick），末尾标玩家这份的版本
    func versionsText(_ g: SGradeScanGame) -> String { versions(g) }   // 单测核这一行
    private func versions(_ g: SGradeScanGame) -> String {
        let parts = ["widescreen", "fps", "gfx", "cheat"].compactMap { c -> String? in
            guard let v = g.available[c], let p = SGradeStateText.pick(v, mine: g.mine) else { return nil }
            return x(c == "cheat" ? "cat.cheatPlain" : "cat." + c) + " " + p.version
        }
        return parts.joined(separator: zh ? "、" : ", ") + (g.mine.isEmpty ? "" : x("version.mine").replacingOccurrences(of: "{0}", with: g.mine))
    }

    private func gains(_ g: SGradeScanGame) -> String {
        var parts: [String] = []
        if (g.patches["widescreen"] ?? 0) > 0 { parts.append(x("cat.widescreen")) } else if g.ownWiden { parts.append(x("cat.ownWiden")) }
        if (g.patches["fps"] ?? 0) > 0 { parts.append(x("cat.fps")) }
        if (g.patches["gfx"] ?? 0) > 0 { parts.append(x("cat.gfx")) }
        if let n = g.patches["cheat"], n > 0 { parts.append(x("cat.cheat").replacingOccurrences(of: "{0}", with: String(n))) }
        if parts.isEmpty && g.bfDue { parts.append(x("bf")) }   // 没有补丁、只缺片上读取用的着色器
        return parts.joined(separator: zh ? "、" : ", ")
    }

    // Smaller, muted group headings; game rows share the page's leading edge and a common description column.
    private func group(_ title: String, _ rows: [(String, String)], gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(rows.count)").font(LauncherTheme.TypeStyle.caption).foregroundStyle(gold ? SGradeCardView.gold : .secondary)
            list(rows)
        }
    }

    private func list(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: LauncherTheme.Space.large, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, r in
                GridRow(alignment: .firstTextBaseline) {
                    Text(r.0).font(LauncherTheme.TypeStyle.detail).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, LauncherTheme.Space.small)
                        .gridCellColumns(r.1.isEmpty ? 2 : 1)
                    if !r.1.isEmpty {
                        Text(r.1).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, LauncherTheme.Space.small)
                    }
                }
                if index < rows.count - 1 {
                    Divider().opacity(0.18).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    /// 行按钮上的字：正在做的「正在升级 37%」（没百分比「正在升级…」）、排着的「排队中」、做完 / 已没有要补的「已完成」、其余「升级」
    func rowTitle(_ id: String) -> String {
        switch states[id] {
        case "running": return progress[id].map { x("rowProgress").replacingOccurrences(of: "{0}", with: String(Int(($0 * 100).rounded(.down)))) } ?? x("rowBusy")
        case "queued": return x("queued")
        case "done": return x("done")
        case "skipped": return x("skipped")     // 轮到时这款正在玩，没升；可再点
        case "incomplete": return x("resume")   // 出错或被停，再点接着升（已做完的段跳过）
        default: return upgrading.contains(id) ? x("rowBusy") : locked(id) ? x("done") : x("row")
        }
    }

    /// 「可以升级」组：每行 名字 · 能补什么 · 「升级」（升级中写「正在升级…」不可点）
    private func upgradeGroup(_ rows: [SGradeScanGame]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(x("yes")) · \(rows.count)").font(LauncherTheme.TypeStyle.caption).foregroundStyle(SGradeCardView.gold)
                Spacer()
                let free = rows.map(\.id).filter { !locked($0) }
                Toggle(x("selectAll"), isOn: Binding(get: { !free.isEmpty && free.allSatisfy(selected.contains) },
                                                     set: { selected = $0 ? Set(free) : [] }))
                    .toggleStyle(PadToggleStyle(.checkbox)).font(LauncherTheme.TypeStyle.caption).disabled(free.isEmpty).controllerID("sgrade.upgrade.selectAll")
            }
            Grid(alignment: .leading, horizontalSpacing: LauncherTheme.Space.large, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, g in
                    GridRow(alignment: .center) {
                        let busy = locked(g.id)
                        Toggle("", isOn: Binding(get: { selected.contains(g.id) && !busy }, set: { if $0 { selected.insert(g.id) } else { selected.remove(g.id) } }))
                            .toggleStyle(PadToggleStyle(.checkbox)).labelsHidden().disabled(busy).controllerID("sgrade.upgrade.pick." + g.id)
                        Text(g.name).font(LauncherTheme.TypeStyle.detail).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, LauncherTheme.Space.small)
                        Text(gains(g)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, LauncherTheme.Space.small)
                        Button(rowTitle(g.id)) { upgrade([g.id]); selected.remove(g.id) }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                            .disabled(busy).controllerID("sgrade.upgrade.row." + g.id).fixedSize()
                    }
                    if index < rows.count - 1 { Divider().opacity(0.18).gridCellUnsizedAxes(.horizontal) }
                }
            }
        }
    }
    private var closeButton: some View {
        Button(x("close")) { close() }.controllerButtonStyle(LauncherSecondaryButtonStyle())
            .controllerID("sgrade.upgrade.close").controllerShortcut(.back).fixedSize()
    }
}

/// 升级中的进度（开始按钮底部的细条）：有百分比画实条，没有（排队 / 作业还没给出）画来回走的不定条
struct SGradeUpgradeBar: View {
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.18))
                if let p = progress {
                    Capsule().fill(SGradeCardView.gold).frame(width: max(4, g.size.width * p)).animation(.easeOut(duration: 0.3), value: p)
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { t in
                        let x = (t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4)) / 1.4
                        Capsule().fill(SGradeCardView.gold).frame(width: g.size.width * 0.3).offset(x: (g.size.width * 1.3) * x - g.size.width * 0.3)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 3).accessibilityHidden(true)
    }
}

/// 升级中的卡片（小图标）：压暗一层、中间进度环 + 百分比；没有百分比时环转圈
struct SGradeUpgradeRing: View {
    let progress: Double?
    let side: CGFloat
    /// 排在队里还没轮到：只写「排队中」，不转圈（不冒充在升）
    var queuedText: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let d = max(34, side * 0.34)
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(.black.opacity(0.45))
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 4)
                if let q = queuedText {
                    Text(q).font(.manrope(max(9, d * 0.2), .bold)).foregroundStyle(.white).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                } else if let p = progress {
                    Circle().trim(from: 0, to: max(0.02, p)).stroke(SGradeCardView.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.3), value: p)
                    Text("\(Int((p * 100).rounded(.down)))%").font(.manrope(max(10, d * 0.26), .bold)).foregroundStyle(.white).monospacedDigit()
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { t in
                        Circle().trim(from: 0, to: 0.28).stroke(SGradeCardView.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                    }
                }
            }
            .frame(width: d, height: d)
        }
        .accessibilityElement().accessibilityIdentifier("sgrade.upgrading.card")
    }
}
