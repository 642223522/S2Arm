// S2Arm（不是上游文件）：「S 级优化升级」页（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。
//   打开即查（作业 sgradeScan，pack/jobs/sgrade.py）：逐款找原始程序（存下的 → 解包缓存 → Mac 版 → 原件），按本地补丁库报这个版本能补什么；
//   分组显示：可升级 / 没有对应补丁 / 出包时选了不打入 / 没找到原始程序（要重新出包覆盖更新）。一款都升不了 → 只给「确认」。
//   Mac 不用操作（启动器打开时后台补、开游戏时兜底）；iPhone 两个按钮都走 installUpdate（只换程序、资源包不推），sgradeUpgrade 让壳已是本版也重组。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct SGradeScanGame: Identifiable, Equatable {
    let id: String, name: String, program: String, total: Int, patches: [String: Int], iphone: Bool, off: Bool, ownWiden: Bool
    /// 这款的显示版本与补丁库里「别的版本」按类的版本号（作业层 versions，只收这一版没有的类；作业层 feat/sgrade-state）
    let mine: String, available: [String: [String]]
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""; name = d["name"] as? String ?? id; program = d["program"] as? String ?? "none"
        total = (d["total"] as? NSNumber)?.intValue ?? 0; iphone = d["iphone"] as? Bool ?? false; off = d["off"] as? Bool ?? false
        ownWiden = d["ownWiden"] as? Bool ?? false   // S2Arm 通用满屏（作业层 total 已算它 +1）
        let v = d["versions"] as? [String: Any] ?? [:]
        mine = v["mine"] as? String ?? ""; available = (v["available"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String] }.filter { !$0.value.isEmpty }
        patches = (d["patches"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
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
        SGradeUpgradeBody(games: games, failure: failure.map(loc.backend), zh: loc.cjkPunctuation, busy: model.busy,   // 作业层原句按界面语言显示
                          x: { BackendText.launcherText("sgrade.upgrade." + $0, language: lang) },
                          upgrade: { mode in model.updatePhone(acceptStale: false, repack: [], language: lang, mode: mode, sgradeUpgrade: true); dismiss() },
                          close: { dismiss() })
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
    let busy: Bool
    let x: (String) -> String
    let upgrade: (String) -> Void
    let close: () -> Void
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
                    if failure == nil, upgrades.contains(where: \.iphone) {
                        ViewThatFits(in: .horizontal) {
                            HStack { installButton; exportButton; Spacer(); closeButton }
                            VStack(alignment: .leading, spacing: 8) { installButton; exportButton; closeButton }
                        }
                    } else {
                        Spacer()
                        Button(x("ok")) { close() }.controllerButtonStyle(LauncherPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction).controllerID("sgrade.upgrade.ok").controllerShortcut(.rightTrigger, .back)
                    }
                }.disabled(failure == nil && upgrades.contains(where: \.iphone) && busy)
            }
        }
        .launcherSheet(.form, height: nil)
        .accessibilityIdentifier("sgrade.upgrade")
    }

    private var upgrades: [SGradeScanGame] { (games ?? []).filter { $0.found && $0.total > 0 && !$0.off } }

    @ViewBuilder private var content: some View {
        if let failure {
            Text(failure).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
        } else if let games {
            let found = games.filter(\.found)
            let yes = upgrades, off = found.filter { $0.total > 0 && $0.off }
            let noVer = found.filter { $0.total == 0 && !$0.available.isEmpty }, no = found.filter { $0.total == 0 && $0.available.isEmpty }
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
                    group(x("yes"), yes.map { ($0.name, gains($0)) }, gold: true)
                    if !noVer.isEmpty { group(x("no.version"), noVer.map { ($0.name, versions($0)) }) }
                    if !no.isEmpty { group(x("no.none"), no.map { ($0.name, "") }) }
                    if !off.isEmpty { group(x("off"), off.map { ($0.name, "") }) }
                    if !missing.isEmpty { group(x("missing"), missing.map { ($0.name, "") }) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                LauncherReadingPane { groups }
                Text(x("macNote")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if yes.contains(where: \.iphone) {
                    Text(x("iphoneNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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

    private var installButton: some View {
        Button(x("install")) { upgrade("device") }.controllerButtonStyle(LauncherPrimaryButtonStyle())
            .controllerID("sgrade.upgrade.install").controllerShortcut(.rightTrigger).fixedSize()
    }
    private var exportButton: some View {
        Button(x("export")) { upgrade("export") }.controllerButtonStyle(LauncherSecondaryButtonStyle())
            .controllerID("sgrade.upgrade.export").controllerShortcut(.rightTrigger, focused: true).fixedSize()
    }
    private var closeButton: some View {
        Button(x("close")) { close() }.controllerButtonStyle(LauncherSecondaryButtonStyle())
            .controllerID("sgrade.upgrade.close").controllerShortcut(.back).fixedSize()
    }
}
