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

    /// 「更新这款」：就是这一款的推到 iPhone（通用壳下 install = push_game，只推这一款、按本版重新准备）
    func updateSuggested(_ game: GameSummary) { install(game) }

    /// 原因 → 共享文案键（libGen = 库缺新代数内容，用着色器那条文案）（launchers/shared/experience.v1.json launcher.items，六种语言）；不认识的原因不显示
    static func updateReasonKey(_ reason: String) -> String? {
        ["rewriter": "update.hint.reason.rewriter", "hostAbi": "update.hint.reason.hostAbi", "shader": "update.hint.reason.shader", "libGen": "update.hint.reason.shader"][reason]
    }
}
