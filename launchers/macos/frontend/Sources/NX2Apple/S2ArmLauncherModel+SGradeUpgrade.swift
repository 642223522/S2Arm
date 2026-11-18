// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// S 级优化升级（11-18 维护者：「改成不自动运行，玩家手动点击 S 级优化再升级；升级过程给小图标和开始游戏按钮上加进度动画，
///   不阻断玩家干别的，同时此时不能新开此游戏」；随后：「可以做批量升级，名字写明白就是批量升级……有全选功能没问题」）。
///   排队只在作业层一份（sgradeUpgradeBatch，Mac / Windows 共用；关掉升级页或窗口队列照常跑）：界面只提交 / 追加号、调停止、读状态。
///   状态来源：跑队列的作业事件（type=batch 每款 start / end，progress 带 gameId）实时更新；队列在跑时每 1.5 秒查一次
///   sgradeUpgradeStatus（追加进来的、或别的窗口起的队列也看得到）；都盖在游戏库 catalog 的 sgradeState / sgradeProgress 上。
///   升级中这款卡片与开始按钮画进度、开始按钮不可点（作业层按款锁兜底），其他游戏照常；资源限额（后台档、核 / 内存各一半、玩游戏时 1 路）在作业层
struct SGradeLive: Equatable { var state: String; var progress: Double? }

extension S2ArmLauncherModel {
    /// 这款在升级队列里的状态：queued / running / done / skipped / incomplete；不在队里为 nil
    func sgradeState(_ gameID: String) -> String? {
        if let live = sgradeLive[gameID] { return live.state }
        return games.first { $0.id == gameID }?.sgradeState
    }
    /// 这款正在升级或排队（含旧字段 sgradeUpgrading）
    func sgradeUpgrading(_ gameID: String) -> Bool {
        let st = sgradeState(gameID)
        return st == "running" || st == "queued" || (st == nil && games.contains { $0.id == gameID && $0.sgradeUpgrading })
    }
    /// 这款排在队里、还没轮到（一次只升一款）
    func sgradeQueued(_ gameID: String) -> Bool { sgradeState(gameID) == "queued" }
    /// 在升的进度 0–1；排队 / 还没给出百分比为 nil
    func sgradeProgress(_ gameID: String) -> Double? {
        guard sgradeState(gameID) == "running" else { return nil }
        return sgradeLive[gameID]?.progress ?? games.first { $0.id == gameID }?.sgradeProgress
    }
    /// 这一批：第几款 / 共几款（没在跑为 nil）
    var sgradeBatch: SGradeBatch? {
        let b = sgradeBatchLive ?? provider.library.sgradeBatch
        return b?.running == true ? b : nil
    }

    /// 单款「升级」或「批量升级所选」：都提交给作业层队列（没在跑就由这次的作业跑队列，在跑就追加到队尾、作业立刻返回）
    func upgradeSGrade(_ gameIDs: [String]) {
        let ids = gameIDs.filter { !sgradeUpgrading($0) }
        guard !ids.isEmpty else { return }
        for id in ids { sgradeLive[id] = SGradeLive(state: "queued", progress: nil) }   // 先画排队中，状态以作业层为准
        let sink = EventSink { [weak self] e in
            guard let id = e.fields["gameId"] as? String else { return }
            let f = e.fields
            Task { @MainActor in self?.ingestSGrade(id: id, event: e.ev, fields: f) }
        }
        Task { [weak self] in
            guard let self else { return }
            self.pollSGrade()
            do { _ = try await self.saveJob("sgradeUpgradeBatch", gameID: "", extra: ["gameIds": ids], events: sink) }
            catch { self.failAction(error.localizedDescription, game: ids.count == 1 ? ids[0] : nil) }   // 提交没成：就近写原因，不弹框
            self.refresh()
        }
    }

    /// 停止整批：排着的不做，在升的那款作业层按记号保留已做完的段（显示「升级未完成」），已做完的不动
    func stopSGrade() {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.saveJob("sgradeUpgradeStop", gameID: "") }
            catch { NSLog("S2Arm：停止 S 级优化升级没成：%@", error.localizedDescription) }
            await self.readSGradeStatus()
            self.refresh()
        }
    }

    /// 跑队列作业的一条事件：batch start → 在升；batch end → 结局（done / skipped / incomplete…）；progress done/total → 进度
    func ingestSGrade(id: String, event: String, fields f: [String: Any]) {
        if let i = (f["index"] as? NSNumber)?.intValue, let n = (f["count"] as? NSNumber)?.intValue {
            sgradeBatchLive = SGradeBatch(running: true, index: i, count: n)
        }
        if f["type"] as? String == "batch" || event == "batch" {
            let phase = f["phase"] as? String
            if phase == "start" { sgradeLive[id] = SGradeLive(state: "running", progress: 0) }
            else if phase == "end" { sgradeLive[id] = SGradeLive(state: f["status"] as? String == "updated" || f["status"] as? String == "unchanged" ? "done" : (f["status"] as? String ?? "done"), progress: nil); refresh() }
            return
        }
        if let done = (f["done"] as? NSNumber)?.doubleValue, let total = (f["total"] as? NSNumber)?.doubleValue, total > 0 {
            sgradeLive[id] = SGradeLive(state: "running", progress: min(1, max(0, done / total)))
        }
    }

    /// 队列在跑时每 1.5 秒查一次作业层状态（只起一个轮询）；跑过、停了再重读一次游戏库
    func pollSGrade() {
        guard !sgradePolling else { return }
        sgradePolling = true
        Task { [weak self] in
            var ran = false
            while let self, !Task.isCancelled {
                let running = await self.readSGradeStatus()
                if !running { break }
                ran = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self?.sgradePolling = false
            if ran { self?.refresh() }   // 一次都没在跑：游戏库不用重读
        }
    }

    /// 读 sgradeUpgradeStatus，更新各款状态与批次；返回队列是否还在跑
    @discardableResult
    func readSGradeStatus() async -> Bool {
        guard let r = try? await saveJob("sgradeUpgradeStatus", gameID: "") else { return false }
        let running = r["running"] as? Bool ?? false
        sgradeBatchLive = SGradeBatch(catalog: r)
        var live: [String: SGradeLive] = [:]
        for g in r["games"] as? [[String: Any]] ?? [] {
            guard let id = g["gameId"] as? String, let st = g["state"] as? String else { continue }
            live[id] = SGradeLive(state: st, progress: (g["progress"] as? NSNumber)?.doubleValue)
        }
        sgradeLive = live
        return running
    }

    /// 启动器打开 / 重读游戏库时：作业层队列还在跑（别的窗口起的）就接着轮询
    func resumeSGradeWatch() { if provider.library.sgradeBatch?.running == true { pollSGrade() } }
}
