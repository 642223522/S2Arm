// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import S2ArmAppleAdapter

/// 0.6.0「建议更新」（通用壳开关后面，《0.6.0 极简流程》界面一节）：启动器打开、出包 / 手机作业做完时快速比对，对不上的款封面出角标、选中写原因 +「更新这款」。
///   玩家点了才做、只做这一款（就是这一款的「推到 iPhone」，推的时候按本版重新准备）；不点照旧能用，不拦任何操作。
extension S2ArmLauncherModel {
    func refreshUpdateHints() {
        Task {
            // 读不到不弹框（附带的提示，不是玩家点的操作），但不吞：原因记日志，提示清空、界面照旧
            do { updateHints = try await provider.updateHints() ?? [:] }
            catch { updateHints = [:]; NSLog("S2Arm updateHints: %@", String(describing: error)) }
        }
    }

    /// 这款对不上的原因（空 = 不用提示）
    func updateReasons(_ game: GameSummary) -> [String] { updateHints[game.id.uppercased()] ?? [] }

    /// 「更新这款」：这一款的推到 iPhone（通用壳下 install = push_game，只推这一款、按本版重新准备），但只更新装过它的设备（11-21）：
    ///   装到这款自己的装机记录那台（不用上次给别的款选的那台）；请求带 onlyInstalled，作业层只推装过这款的设备，
    ///   连着一台没装过的设备时不推、报 game_not_on_device（玩家反馈：更新这款把游戏装进了没打算装的 iPad）
    static let onlyInstalledKey = "onlyInstalled"   // 走 install 的 accept 通道：每个键原样成请求里的布尔，排队 / 失败页重试都带着
    func updateSuggested(_ game: GameSummary) {
        let own = game.iphoneInstallDevice.flatMap { $0.isEmpty ? nil : $0 }
        install(game, device: own, accept: [Self.onlyInstalledKey])
    }

    /// 原因 → 共享文案键（libGen = 库缺新代数内容，用着色器那条文案）（launchers/shared/experience.v1.json launcher.items，六种语言）；不认识的原因不显示
    static func updateReasonKey(_ reason: String) -> String? { BackendText.updateReasonKeys[reason] }   // 共享体验表 update_reasons（11-19 结构 9）
}
