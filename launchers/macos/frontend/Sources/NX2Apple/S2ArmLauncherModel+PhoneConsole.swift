// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// 0.6.0 iPhone 总控台（通用壳开关后面，《0.6.0 极简流程》界面一节「iPhone 总控台」）：游戏库首位固定「S2Arm」卡，选中它就是这台手机的总控台。
///   不加门、不加锁：要手机的按钮只在没连时灰并就近写原因，其余都能点。
extension S2ArmLauncherModel {
    /// 首位卡的选中号（不是游戏号，永远排第一、不能删不能挪、不算进游戏数）
    static let consoleID = "s2arm.console"
    var consoleSelected: Bool { selectedID == Self.consoleID }

    func refreshPhoneOverview(probe: Bool = false) {
        Task {
            // 读不到不弹框（首位卡是附带的入口），但不吞：记日志，保持上次的值
            do {
                let o = try await provider.phoneOverview(probe: probe)
                phoneOverview = o
                if let o, !o.phones.contains(where: { $0.device == consoleDevice }) { consoleDevice = nil }
                seedConsoleSelection()
            } catch { NSLog("S2Arm phoneOverview: %@", String(describing: error)) }
        }
    }

    /// 总控台当前这台：选过的那台；没选过 → 连着的那台 → 最近同步过的那台
    var consolePhone: PhoneOverview.Phone? {
        guard let phones = phoneOverview?.phones, !phones.isEmpty else { return nil }
        if let d = consoleDevice, let p = phones.first(where: { $0.device == d }) { return p }
        if let p = phones.first(where: { if case .some(.some) = $0.online { return true }; return false }) { return p }
        return phones.max { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }

    /// 首位卡状态行（流程稿表格，自上而下取第一条成立的）
    enum ConsoleStatus: Equatable {
        case introduce                       // 从没装过、也没连过：「在 iPhone 上玩」介绍卡
        case updating(done: Int, total: Int) // 正在更新所选
        case notConnected(lastSeen: Date?)   // 问过 USB、没连
        case notInstalled
        case appOutdated
        case expired
        case expiring(days: Int)             // ≤ 2 天
        case suggested(count: Int)
        case ok(days: Int?)                  // 还剩约 N 天（证书用户没有估值时 nil）
    }

    func consoleStatus(now: Date = Date()) -> ConsoleStatus {
        guard let p = consolePhone else { return .introduce }
        if consoleUpdating { let p = consoleProgress; return .updating(done: p.done, total: p.total) }
        if case .some(.none) = p.online { return .notConnected(lastSeen: p.lastSeen) }
        if !p.installed { return .notInstalled }
        if !p.shellCurrent { return .appOutdated }
        let days = p.expiresAtEstimate.map { Self.daysLeft(until: $0, now: now) }
        if let d = days, d <= 0 { return .expired }
        if let d = days, d <= 2 { return .expiring(days: d) }
        let n = p.games.filter { $0.state == .suggested }.count
        if n > 0 { return .suggested(count: n) }
        return .ok(days: days)
    }

    /// 还剩几天（不足一天按一天，过了就是 0）：到期时刻本来就是估的，界面写「约」
    static func daysLeft(until end: Date, now: Date) -> Int {
        let s = end.timeIntervalSince(now)
        return s <= 0 ? 0 : Int((s / 86_400).rounded(.up))
    }

    /// 这款在当前这台上的状态（② 一行）；表里没有的款按没推过
    func consoleGame(_ game: GameSummary) -> PhoneOverview.Game {
        consolePhone?.games.first { $0.gameId == game.id.uppercased() }
            ?? PhoneOverview.Game(gameId: game.id.uppercased(), state: .notPushed, reasons: [], dataOnComputer: nil)
    }

    /// 建议更新的默认勾上（每次读到新总览时补勾新出现的建议更新款；玩家取消的不重勾，直到它的状态变了）
    func seedConsoleSelection() {
        let suggested = Set(consolePhone?.games.filter { $0.state == .suggested }.map(\.gameId) ?? [])
        consoleSelection.formUnion(suggested.subtracting(consoleSeeded))
        consoleSeeded = suggested
    }

    /// 「更新所选」正在跑（作业 pushSelected 占着手机槽）
    var consoleUpdating: Bool { phoneBusy && phoneSession?.kind == .pushSelected }
    /// 这一轮推到第几款 / 共几款（作业每款 begin(i, n)）
    var consoleProgress: (done: Int, total: Int) {
        guard consoleUpdating, let p = phoneSession?.progress, let i = p.index, let n = p.count else { return (0, 0) }
        return (max(i - 1, 0), n)
    }

    /// 「更新所选」：一单作业 pushSelected 按游戏库顺序推总控台这台（作业层一款失败接着推下一款，做不下去的才整轮停）。
    /// ids / device 给了就推这几款到那台（「更新 S2Arm」成功页「更新这 N 款」：刚装好 App 的那台上的 0.5.x 老款）
    func updateSelected(resume: Bool = false, ids: [String]? = nil, device: String? = nil) {
        guard !consoleUpdating, let device = device ?? consolePhone?.device else { return }
        let order = ids ?? games.filter { consoleSelection.contains($0.id.uppercased()) }.map { $0.id.uppercased() }
        guard resume || !order.isEmpty else { return }
        guard !phoneBusy else { phoneQueue.append((nil, { [weak self] in self?.updateSelected(resume: resume, ids: ids, device: device) })); return }
        consolePushing = nil
        start(JobSession(kind: .pushSelected, gameID: nil, name: BackendText.launcherText("console.updateSelected", language: dynamicLanguage)
            .replacingOccurrences(of: "{0}", with: "\(order.count)"))) { [weak self] sink in
            let watch = EventSink { ev in
                if let cur = ev.fields["current"] as? String { Task { @MainActor in self?.consolePushing = cur.uppercased() } }
                sink.emit(ev)
            }
            defer { Task { @MainActor in self?.consolePushing = nil; self?.refreshPhoneOverview() } }
            _ = try await self?.provider.pushSelected(gameIds: order, device: device, resume: resume, events: watch)
            return nil
        }
    }

    /// 「停下」：取消这一单（作业层推完的留着；没推完的那款下次续推）
    func stopUpdateSelected() { if consoleUpdating { stopPhone() } }

    // ---- 顶栏动态窗口（《0.6.0 极简流程》iPhone 总控台「五」）：正在做和 App 相关的作业时显示进度，做完闪 ✓，失败留橙色「!」 ----

    /// 正在跑的手机作业：进度（拿不到为 nil）+ 一行小字；没有 = 普通图标
    var dynamicJob: (fraction: Double?, label: String)? {
        guard phoneOverview != nil, phoneBusy, let s = phoneSession else { return nil }
        if s.kind == .pushSelected {   // 更新所选算一件：「推送 3/7」+ 总进度
            let p = consoleProgress, total = max(p.total, 1)
            let text = BackendText.launcherText("dynamic.batch", language: dynamicLanguage).replacingOccurrences(of: "{0}", with: "\(min(p.done + 1, total))").replacingOccurrences(of: "{1}", with: "\(total)")
            return (s.progress.overall ?? Double(p.done) / Double(total), text)
        }
        return (s.progress.fraction, s.name)
    }

    /// 界面语言（setUILanguage 写进作业环境的那个，共享文案同一套语言码）
    var dynamicLanguage: String { provider.client.environment.uiLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? "zh-Hans" }

    func dynamicFinished(_ state: JobOutcome.State) {
        guard phoneOverview != nil else { return }
        if state == .completed {
            dynamicDone = true
            Task { try? await Task.sleep(for: .seconds(2)); dynamicDone = false }
        } else { dynamicAlert = true }
    }

    /// 点动态窗口：直接到总控台（选中首位卡），看过就收起橙色「!」
    func openConsoleFromTopBar() {
        dynamicAlert = false
        goToLibrary()
        selectedID = Self.consoleID
    }
}
