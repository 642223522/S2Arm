// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// S 级优化单款升级（11-18 维护者：「改成不自动运行，玩家手动点击 S 级优化再升级；升级过程给小图标和开始游戏按钮上加进度动画，
///   不阻断玩家干别的，同时此时不能新开此游戏」）。
///   作业 sgradeUpgradeGame（{gameId}，pack/jobs：Mac 运行版本补丁 → _bf → 有 iPhone 程序件再补 iPhone）在后台跑，不占主槽：
///   别的游戏、设置照常可用；这款的卡片与开始按钮画进度，开始按钮不可点（作业层按款 S 级锁兜底：升级中开这款回 sgrade_upgrading）。
///   进度按阶段：stageIndex / stageCount（2 或 3 段）算百分比；_bf 那段（stageKey sgrade.bf）可能几分钟、没有段内百分比，画不定进度。
///   一次跑一款，点了多款就排队；做完重读游戏库（金色 S、升级未完成标记跟着变）。没做完就退出启动器的，作业层留标记，
///   游戏库 sgradeIncomplete 为真，这款显示「升级未完成，点 S 级优化继续」
extension S2ArmLauncherModel {
    /// 这款正在升级或排队升级（含游戏库 sgradeUpgrading：别的启动器进程起的升级还在跑）
    func sgradeUpgrading(_ gameID: String) -> Bool {
        sgradeUpgrades[gameID] != nil || games.contains { $0.id == gameID && $0.sgradeUpgrading }
    }
    /// 这款的升级进度 0–1；排队中 / 作业还没给出百分比为 nil
    func sgradeProgress(_ gameID: String) -> Double? { sgradeUpgrades[gameID] ?? nil }
    /// 这款排在队里、还没轮到（一次只升一款）
    func sgradeQueued(_ gameID: String) -> Bool { sgradeQueue.contains(gameID) }

    /// 玩家点了升级（单款或「批量升级所选」）：排进队列（已在队里 / 在升的不重复），空着就马上起；批量总数跟着加
    func upgradeSGrade(_ gameIDs: [String]) {
        var added = 0
        for id in gameIDs where sgradeUpgrades[id] == nil {
            sgradeUpgrades[id] = .some(nil)
            sgradeDoneIDs.remove(id)
            sgradeQueue.append(id)
            added += 1
        }
        if added > 0 { sgradeBatch = (sgradeBatch?.done ?? 0, (sgradeBatch?.total ?? 0) + added) }
        pumpSGrade()
    }

    /// 中途停止：排着的不做了，在升的那款请作业停（作业层按记号保留已做完的段，没做完的那款显示「升级未完成」）；已做完的款不动
    func stopSGrade() {
        for id in sgradeQueue { sgradeUpgrades[id] = nil }
        sgradeQueue.removeAll()
        sgradeTask?.cancel()
    }

    /// 阶段事件 → 进度：第 i 段开始 = (i−1)/n；_bf 段没有段内百分比 → .some(nil)（画不定进度）；不是阶段事件 → nil（不改）
    nonisolated static func sgradeStageProgress(_ f: [String: Any]) -> Double?? {
        guard let i = (f["stageIndex"] as? NSNumber)?.doubleValue, let n = (f["stageCount"] as? NSNumber)?.doubleValue, n > 0 else { return nil }
        if f["stageKey"] as? String == "sgrade.bf" { return .some(nil) }
        return .some(min(1, max(0, (i - 1) / n)))
    }

    func pumpSGrade() {
        guard sgradeRunning == nil, !sgradeQueue.isEmpty else { return }
        let id = sgradeQueue.removeFirst()
        sgradeRunning = id
        let sink = EventSink { [weak self] e in
            guard let frac = Self.sgradeStageProgress(e.fields) else { return }
            Task { @MainActor in if self?.sgradeUpgrades[id] != nil { self?.sgradeUpgrades[id] = frac } }
        }
        sgradeTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.saveJob("sgradeUpgradeGame", gameID: id, events: sink); self.sgradeDoneIDs.insert(id) }
            catch where !Task.isCancelled { self.failAction(error.localizedDescription, game: id) }   // 没成：这款上就近写原因（同其他按款操作），不弹框
            catch {}   // 玩家点了停止：不当失败
            self.sgradeUpgrades[id] = nil
            self.sgradeRunning = nil
            self.sgradeTask = nil
            if let b = self.sgradeBatch { self.sgradeBatch = self.sgradeQueue.isEmpty ? nil : (b.done + 1, b.total) }
            self.refresh()
            self.pumpSGrade()
        }
    }
}
