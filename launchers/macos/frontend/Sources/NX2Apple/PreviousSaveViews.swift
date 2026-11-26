// S2Arm（不是上游文件）：回到上一份存档的两处界面（S2ArmLauncherModel+SavePrevious）。
//   PreviousSavePromptHost：开始前「这款上次没能正常读存档，要回到上一份存档吗？」两个按钮，之后「可以随时换回来」
//   PreviousSaveRow：齿轮页「回到上一份存档」（有上一份才显示）
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter
import SwiftUI

struct PreviousSavePromptHost: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }
    var body: some View {
        let p = model.previousSavePrompt
        Color.clear.frame(width: 0, height: 0)
            .alert(t("save.previous.ask.title"),
                   isPresented: Binding(get: { model.previousSavePrompt != nil }, set: { if !$0, let p, model.previousSavePrompt?.id == p.id { model.answerPreviousSave(p, restore: false) } })) {
                Button(t("save.previous.ask.restore")) { if let p { model.answerPreviousSave(p, restore: true) } }
                Button(t("save.previous.ask.start"), role: .cancel) { if let p { model.answerPreviousSave(p, restore: false) } }
            } message: {
                Text(t(p?.trouble == "guardRed" ? "save.previous.ask.guard" : "save.previous.ask.crash"))
            }
            .background(Color.clear.frame(width: 0, height: 0)
                .alert(t("save.previous.done.title"), isPresented: Binding(get: { model.previousSaveSwitched != nil }, set: { if !$0 { model.previousSaveSwitched = nil } })) {
                    Button(t("save.previous.done.ok"), role: .cancel) { model.previousSaveSwitched = nil }
                } message: {
                    Text(t("save.previous.done.body"))
                })
    }
}

/// 齿轮页的一行：有上一份才显示；点了就换（可逆，再点一次换回来），换完由 PreviousSavePromptHost 提示可以换回来
struct PreviousSaveRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    let gameID: String
    let t: (String) -> String
    @State private var has = false
    @State private var working = false
    @State private var failure: String?
    var body: some View {
        Group {
            if has {
                CardGroup(t("save.previous.group")) {
                    CardRow(t("save.previous.action"), detail: failure ?? t("save.previous.action.detail")) {
                        Button(t("save.previous.action.button")) {
                            working = true
                            Task {
                                failure = await model.switchPreviousSave(gameID)
                                working = false
                            }
                        }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle())
                        .disabled(working || model.busy)
                        .controllerID("save.previous.switch")
                    }
                }
            }
        }
        .task { has = (try? await model.previousSave(gameID))?.has ?? false }
    }
}
