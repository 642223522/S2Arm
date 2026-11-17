// S2Arm（不是上游文件）：释放空间（spaceSurvey / spaceFree 作业）。列这款可删的 5 项（解包、中间产物、着色器缓存、Mac 运行版本、
// iPhone 包），每项给大小与「删了会怎样」（作业层定句），可勾选；存档、日志只显示大小、不能删。底部是勾选合计与「释放」：
// 直接删除、不进废纸篓，点了先二次确认；删完重读大小并显示释放了多少。有作业在跑时「释放」置灰，作业层拒绝时显示它的原话。
// 顶上切到「存储总览」（游戏库结构 v3「查」，StorageOverview.swift）：各存放位置占用 / 剩余、公共文件、各款大小。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct FreeSpaceView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let gameID: String
    @State private var chosen: Set<String> = []
    @State private var confirming = false
    @State private var overviewMode = false

    private var game: GameSummary? { model.games.first { $0.id == gameID } }
    private var space: GameSpace? { model.space?.gameId == gameID ? model.space : nil }
    private var total: Int64 { space?.bytes(of: chosen) ?? 0 }
    private var canFree: Bool { !chosen.isEmpty && total > 0 && !model.busy && !model.spaceFreeing && !model.spaceLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // 总览不针对某一款；单款页的游戏名跟在标题后。
                LauncherSheetHeading(overviewMode ? storage("title") : loc.t("s2arm.space.title"),
                                     subtitle: overviewMode ? "" : game?.name ?? space?.name ?? gameID)
                Spacer(minLength: 12)
                if model.spaceFreeing, let note = model.lockWaitNote { Text(loc.backend(note)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary) }
                if model.spaceLoading || model.spaceFreeing || model.overviewLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.top, LauncherTheme.Space.page).padding(.bottom, 16)
            // 切换单独一行，与页头和内容左对齐。两段都是固定的短词，不放游戏名。
            LauncherSegmented(options: [("game", loc.t("s2arm.space.title")), ("overview", storage("title"))],
                              selection: overviewMode ? "overview" : "game") { overviewMode = $0 == "overview" }
            .frame(width: LauncherTheme.Metrics.navigationWidth)
            .accessibilityIdentifier("space.mode")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, 20)
            if let error = model.spaceError {
                Text(loc.backend(error)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, 12)
            }
            if let freed = model.spaceFreed {
                Text(String(format: loc.t("s2arm.space.freed"), Self.size(freed))).font(.manrope(12.5, .semibold))
                    .foregroundStyle(LauncherPalette.ready)
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if overviewMode {
                        StorageOverviewSection(model: model)
                    } else if let space {
                        CardGroup(loc.t("s2arm.space.parts"), footnote: space.sharedBytes > 0 ? String(format: loc.t("s2arm.space.sharedNote"), Self.size(space.sharedBytes)) : "") {
                            ForEach(space.parts) { part in
                                CardRow(loc.backend(part.title), detail: loc.backend(part.rebuild)) {
                                    HStack(spacing: 14) {
                                        Text(Self.size(part.bytes)).font(LauncherTheme.TypeStyle.section).monospacedDigit()
                                            .foregroundStyle(part.bytes > 0 ? .primary : .secondary)
                                        Toggle("", isOn: binding(part.id)).toggleStyle(PadToggleStyle(.checkbox)).labelsHidden()
                                            .disabled(part.bytes == 0 || model.spaceFreeing)
                                            .accessibilityLabel(loc.backend(part.title))
                                    }
                                }
                                if part.id != space.parts.last?.id { CardDivider() }
                            }
                        }
                        CardGroup(loc.t("s2arm.space.kept"), footnote: loc.t("s2arm.space.keptNote")) {
                            ForEach(space.kept) { item in
                                CardRow(keptTitle(item.id)) {
                                    Text(Self.size(item.bytes)).font(LauncherTheme.TypeStyle.section).monospacedDigit().foregroundStyle(.secondary)
                                }
                                if item.id != space.kept.last?.id { CardDivider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section)
            }
            LauncherSheetFooter {
                // 总览页没有可删的东西：不显示「已选」与「直接删除」。
                if !overviewMode {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: loc.t("s2arm.space.total"), Self.size(total))).font(.manrope(14, .bold)).monospacedDigit()
                        Text(loc.t("s2arm.space.direct")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                        if model.busy { Text(loc.t("s2arm.space.busy")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 8)
                if overviewMode {
                    Button(storage("refresh")) { model.loadOverview() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.overviewLoading).controllerShortcut(.secondary)
                }
                Button(loc.t("launch.done")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .controllerShortcut(.rightTrigger, .back, focused: !overviewMode)
                if !overviewMode {
                    Button(loc.t("s2arm.space.free")) { confirming = true }
                        .controllerButtonStyle(LauncherPrimaryButtonStyle()).disabled(!canFree).controllerShortcut(.rightTrigger)
                }
            }
        }
        .alert(String(format: loc.t("s2arm.space.confirmTitle"), Self.size(total)), isPresented: $confirming) {
            Button(loc.t("s2arm.space.confirm"), role: .destructive) {
                let parts = chosen
                chosen = []
                model.freeSpace(gameID, parts: parts)
            }
            Button(loc.t("s2arm.job.cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.loadSpace(gameID) }
        .launcherSheet()
        .onDisappear { model.clearSpaceFreed() }
        .onExitCommand { dismiss() }
    }

    private func storage(_ id: String) -> String { BackendText.launcherText("storage." + id, language: loc.lang.sharedCode) }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { on in if on { chosen.insert(id) } else { chosen.remove(id) } })
    }

    /// 勾选的几项（显示名）+「直接删除、不能撤销」。
    private var confirmMessage: String {
        let names = (space?.parts ?? []).filter { chosen.contains($0.id) }.map { loc.backend($0.title) }.joined(separator: loc.t("s2arm.punct.list"))
        return String(format: loc.t("s2arm.space.confirmMessage"), names)
    }

    private func keptTitle(_ id: String) -> String {
        let key = "s2arm.space.kept." + id
        return loc.t(key) == key ? id : loc.t(key)
    }

    /// 字节 → 「1.2 GB」（同访达：十进制）。
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
