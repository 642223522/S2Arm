// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// S 级优化单款升级（11-18 维护者：「改成不自动运行，玩家手动点击 S 级优化再升级；升级过程给小图标和开始游戏按钮上加进度动画，
///   不阻断玩家干别的，同时此时不能新开此游戏」）。
///   作业 sgradeMac（带 gameId 只升这一款）在后台跑，不占主槽：别的游戏、设置照常可用；这款的卡片与开始按钮画进度，开始按钮不可点。
///   一次跑一款，点了多款就排队；做完重读游戏库（金色 S、升级未完成标记跟着变）。没做完就退出启动器的，作业层留标记，
///   游戏库 sgradeIncomplete 为真，这款显示「升级未完成，点 S 级优化继续」
extension S2ArmLauncherModel {
    /// 这款正在升级或排队升级
    func sgradeUpgrading(_ gameID: String) -> Bool { sgradeUpgrades[gameID] != nil }
    /// 这款的升级进度 0–1；排队中 / 作业还没给出百分比为 nil
    func sgradeProgress(_ gameID: String) -> Double? { sgradeUpgrades[gameID] ?? nil }

    /// 玩家点了升级：排进队列（已在队里 / 在升的不重复），空着就马上起
    func upgradeSGrade(_ gameIDs: [String]) {
        for id in gameIDs where sgradeUpgrades[id] == nil {
            sgradeUpgrades[id] = .some(nil)
            sgradeQueue.append(id)
        }
        pumpSGrade()
    }

    func pumpSGrade() {
        guard sgradeRunning == nil, !sgradeQueue.isEmpty else { return }
        let id = sgradeQueue.removeFirst()
        sgradeRunning = id
        let sink = EventSink { [weak self] e in
            guard e.ev == "progress", let done = (e.fields["done"] as? NSNumber)?.doubleValue,
                  let total = (e.fields["total"] as? NSNumber)?.doubleValue, total > 0 else { return }
            let frac = min(1, max(0, done / total))
            Task { @MainActor in if self?.sgradeUpgrades[id] != nil { self?.sgradeUpgrades[id] = frac } }
        }
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.saveJob("sgradeMac", gameID: id, events: sink) }
            catch { self.failAction(error.localizedDescription, game: id) }   // 没成：这款上就近写原因（同其他按款操作），不弹框
            self.sgradeUpgrades[id] = nil
            self.sgradeRunning = nil
            self.refresh()
            self.pumpSGrade()
        }
    }
}
