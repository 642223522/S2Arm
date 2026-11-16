// S2Arm（不是上游文件）：下游深度方案确认页（pack/downstream/schemes.json、pack/jobs/downstream.py）。
// 这款有下游项目做的专门移植时，导出 iPhone 前问玩家一次用哪套方案。文案全部来自登记表（只写玩家据此选择的事实，中英两份），
// 游戏名用玩家自己游戏包里的名字。选「仍用原版方案」照原版出，不拦；只有物理上做不出来（下游只支持某一版更新）时推荐按钮置灰，
// 旁边写原因和办法。选完 model.chooseDownstream 记下选择（downstreamChoice 作业）并接着导出刚才那一单；之后的出包 / 装机作业按记下的选择分流。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct DownstreamConfirmSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    /// 界面语言（挂弹页处从 Localizer 取；单测离屏渲染时直接给）
    let zh: Bool

    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private var lang: String { zh ? "zh" : "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.section) {
            if let game, let offer = game.downstream, let text = offer.text(lang) {
                LauncherSheetHeading(text.title, subtitle: game.name)
                LauncherReadingPane {
                    VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
                        Text(LauncherCopy.note(text.body)).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
                            ForEach(text.points, id: \.self) { point in
                                Label(LauncherCopy.note(point), systemImage: "checkmark.circle")
                                    .font(LauncherTheme.TypeStyle.detail).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !offer.eligible {
                    Label(LauncherCopy.note(offer.why(lang)), systemImage: "info.circle").font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("downstream.reason")
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button(text.original) { model.chooseDownstream(gameID, scheme: ""); dismiss() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("downstream.original").controllerShortcut(.rightTrigger, focused: true)
                    Button(text.recommend) { model.chooseDownstream(gameID, scheme: offer.id); dismiss() }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle()).disabled(!offer.eligible)
                        .keyboardShortcut(.defaultAction).controllerID("downstream.recommend").controllerShortcut(.rightTrigger)
                }
            }
        }
        .padding(LauncherTheme.Space.page).launcherSheet(.form, height: nil)
    }
}

/// 挂确认页的空视图：LauncherView 的修饰链已经很长，弹页放在这里，那边只加一个 .background
struct DownstreamPromptHost: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    private struct Target: Identifiable { let id: String }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: Binding(get: { model.downstreamPromptFor.map(Target.init) }, set: { if $0 == nil { model.downstreamPromptFor = nil } })) { target in
                DownstreamConfirmSheet(model: model, gameID: target.id, zh: loc.cjkPunctuation)
            }
    }
}
