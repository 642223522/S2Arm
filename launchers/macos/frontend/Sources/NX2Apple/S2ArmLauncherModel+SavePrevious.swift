// S2Arm（不是上游文件）：回到上一份存档（Mac）。作业层 pack/jobs/save_previous.py：
//   savePrevious        → 有没有上一份（<存档>/.s2a_prev）、上一局读存档出没出事（trouble：earlyCrash 开局就崩 / guardRed 存档护栏红行）
//   saveRestorePrevious → 与上一份原子交换；再做一次就换回来
// 开始游戏前：有上一份且上一局出事才问（不拦、不自动覆盖）；回过去之后再告诉玩家可以随时换回来。齿轮页也有同一个入口（有上一份才显示）。
import Foundation
import S2ArmAppleAdapter

struct PreviousSavePrompt: Identifiable {
    let id = UUID()
    let game: GameSummary
    let uiLanguage: String?
    let trouble: String
}

extension S2ArmLauncherModel {
    func previousSave(_ gameID: String) async throws -> (has: Bool, trouble: String) {
        let r = try await saveJob("savePrevious", gameID: gameID)
        return (r["hasPrevious"] as? Bool ?? false, r["trouble"] as? String ?? "")
    }

    func restorePreviousSave(_ gameID: String) async throws {
        _ = try await saveJob("saveRestorePrevious", gameID: gameID)
    }

    /// 开始前要不要问：有上一份、上一局读存档出了事。读不到（旧后端没有这个作业）就不问
    func previousSavePromptIfNeeded(_ game: GameSummary, uiLanguage: String?) async -> PreviousSavePrompt? {
        guard let p = try? await previousSave(game.id), p.has, !p.trouble.isEmpty else { return nil }
        return PreviousSavePrompt(game: game, uiLanguage: uiLanguage, trouble: p.trouble)
    }

    /// 开始前提示的两个按钮：回到上一份（换完照常开局，再提示可以换回来）/ 照常开始
    func answerPreviousSave(_ prompt: PreviousSavePrompt, restore: Bool) {
        previousSavePrompt = nil
        guard restore else { startAfterPreviousSave(prompt.game, uiLanguage: prompt.uiLanguage); return }
        Task {
            do {
                try await restorePreviousSave(prompt.game.id)
                previousSaveSwitched = prompt.game.id
            } catch {
                failAction(error.localizedDescription, game: prompt.game.id)
            }
            startAfterPreviousSave(prompt.game, uiLanguage: prompt.uiLanguage)
        }
    }

    /// 齿轮页入口：玩家自己点；换完提示可以换回来（再点一次就是换回来）
    func switchPreviousSave(_ gameID: String) async -> String? {
        do {
            try await restorePreviousSave(gameID)
            previousSaveSwitched = gameID
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
