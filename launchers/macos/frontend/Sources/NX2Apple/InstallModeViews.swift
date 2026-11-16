// S2Arm（不是上游文件）：一键装到 iPhone 的签名身份（v0.3.0；11-15 维护者：导出不再是装法，游戏库「导出自签包」按钮常驻，设置里没有切换）。
//   InstallModeCard：设置里的一张卡——一键装到 iPhone 用谁签名（Xcode 账号 / 我的开发者证书；Xcode 团队号手填与引导项目从装机页挪来）。
//   InstallModeLine：出包页一行只读签名身份 + 「更改」（打开设置）。
//   PhoneUpdateButton：游戏库右上角「更新 iPhone 上的 S2Arm」（壳比本版旧才出现），有要重新出包的款先三选一。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func ix(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }

struct InstallModeCard: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @AppStorage(S2ArmLauncherModel.teamCodeKey) private var enteredTeamCode = ""
    @State private var showTeam = false
    @State private var openingGuide = false
    @State private var guideFailure: String?

    var body: some View {
        CardGroup(ix(loc, "install.mode.device"), footnote: ix(loc, "install.mode.device_note")) {
            identity.padding(LauncherTheme.Metrics.cardInset)
        }
        .onAppear { showTeam = !enteredTeamCode.isEmpty; model.refreshInstallMode(); model.refreshDevCert() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("env.installMode")
    }

    /// 一键装时的签名身份：开发者证书一栏照用出包页原来那套（导入 / 换 / 删、体检）；不用证书时 Xcode 团队号与引导项目在这里
    @ViewBuilder private var identity: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
            DevCertRow(model: model, title: ix(loc, "install.mode.identity"), appleIdTitle: ix(loc, "install.mode.identity_xcode"), embedded: true)
            if model.devCert?.active != true {
                // Xcode 里还没有团队 / 签不成时的解决办法（引导项目 + 手填团队号）：平时收起，签名身份一栏保持紧凑；手填过团队号的展开着
                Button { showTeam.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(loc.t("s2arm.install.teamManual")).font(.manrope(12.5, .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(showTeam ? 90 : 0))
                    }
                    .foregroundStyle(LauncherPalette.cream.opacity(0.85))
                }
                .controllerButtonStyle(.plain).controllerID("env.teamManual")
                if showTeam {
                VStack(alignment: .leading, spacing: LauncherTheme.Space.large) {
                    VStack(alignment: .leading, spacing: LauncherTheme.Space.medium) {
                        Text(loc.t("s2arm.install.teamGuide.intro")).font(LauncherTheme.TypeStyle.detail)
                        ForEach(1...3, id: \.self) { step in
                            LauncherGuideStep(step, loc.t("s2arm.install.teamGuide.step\(step)"))
                        }
                        Button {
                            openingGuide = true; guideFailure = nil
                            model.openSigningProject { error in
                                openingGuide = false
                                guideFailure = error.map { loc.backend($0.localizedDescription) }
                            }
                        } label: {
                            HStack(spacing: LauncherTheme.Space.small) {
                                if openingGuide { ProgressView().controlSize(.small).frame(width: LauncherTheme.Metrics.icon) }
                                Text(loc.t("s2arm.install.teamGuideOpen"))
                            }
                        }
                            .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("env.teamGuideOpen")
                            .disabled(openingGuide)
                            .padding(.leading, 22 + LauncherTheme.Space.medium)
                        if let guideFailure {
                            Text(loc.t("s2arm.install.teamGuide.failed").replacingOccurrences(of: "{0}", with: guideFailure))
                                .font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("env.teamGuide.failure")
                        }
                    }
                    CardDivider()
                    VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
                        Text("Team ID").font(LauncherTheme.TypeStyle.section)
                        Text(loc.t("s2arm.install.teamManualHelp")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(loc.t("s2arm.install.teamManualField"), text: $enteredTeamCode,
                                  prompt: Text(loc.t("s2arm.install.teamManualField")).foregroundColor(LauncherTheme.Colors.secondary))
                            .textFieldStyle(LauncherTextFieldStyle()).font(.mono(13)).frame(maxWidth: 300)
                            .accessibilityLabel("Team ID").accessibilityIdentifier("env.teamId")
                    }
                }
                .padding(LauncherTheme.Space.large).launcherPanel()
                }
            }
        }
    }
}

/// 出包页：一键装用谁签名 + 「更改」（打开设置那张卡）
struct InstallModeLine: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 12) {
            LauncherRowIcon("signature")
            Text(ix(loc, "install.mode.summary").replacingOccurrences(of: "{0}", with: summary)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(ix(loc, "install.mode.change")) { model.showEnvironment = true }
                .controllerButtonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                .accessibilityIdentifier("export.installMode.change")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LauncherPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
        .onAppear { model.refreshInstallMode(); model.refreshDevCert() }
    }

    private var summary: String {
        model.signIdentity == "devcert" ? ix(loc, "export.sign.devcert") : ix(loc, "install.mode.identity_xcode")
    }
}

/// 游戏库右上角：壳比本版旧才出现，「更新 iPhone 上的 S2Arm」（自签的玩家点游戏的「导出自签包」导出新版）。
///   放在标题栏那一排（同 batchPill）：那里拿不到 Localizer 环境对象（真机起局实测取它即崩），文字按调用方给的界面语言从共用规格取
struct PhoneUpdateButton: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String
    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        if model.phoneUpdate != nil {
            Button { model.requestPhoneUpdate(language: language) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.circle")
                    Text(t("update.button.device")).font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
            .controllerID("top.phoneUpdate").controllerShortcut(.rightTrigger, focused: true)
            .alert(t("update.confirm.title"), isPresented: Binding(get: { model.updateConfirm != nil }, set: { if !$0 { model.updateConfirm = nil } }),
                   presenting: model.updateConfirm) { u in
                Button(t("update.confirm.repack")) { model.updatePhone(acceptStale: true, repack: u.stale.map(\.id), language: language) }
                Button(t("update.confirm.later")) { model.updatePhone(acceptStale: true, repack: [], language: language) }
                Button(t("update.confirm.cancel"), role: .cancel) {}
            } message: { u in
                Text(t("update.confirm.body").replacingOccurrences(of: "{0}", with: u.stale.map(\.name).joined(separator: "」「"))
                        .replacingOccurrences(of: "{1}", with: "\(u.games.count - u.stale.count)"))
            }
            // 更新会让手机上别的电脑装的游戏暂时不能玩：在更新页里问（PhoneJobPanel.dropAsk），不在这里弹框
        }
    }
}
