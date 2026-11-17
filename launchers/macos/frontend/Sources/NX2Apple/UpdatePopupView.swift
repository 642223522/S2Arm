// S2Arm（不是上游文件）：更新流程（11-13 维护者定稿草图）。打开时最多一个弹窗，只给最新一期：
//   ① 有新版：版本 + 这版的更新说明（签名清单 notes 的 sections），「以后再说」/「现在更新并重启」；
//   ② 更新后第一次打开：「已更新到 vX」+ 这版的亮点（notes.highlights），「知道了」。
// 「消息」面板：公告（最新在前）和更新说明都在这里，旧的只在这里看、不弹不算未读。判定全在 pack/jobs/updater.py inbox，这里只显示。
import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 更新说明里的一条：{zh-Hans, en?}；英文没有就用中文
private func noteText(_ item: [String: Any], _ language: String) -> String {
    LauncherCopy.note((language == "en" ? item["en"] as? String : nil) ?? item["zh-Hans"] as? String ?? "")
}

private func releasePage(_ version: String) -> URL? { URL(string: "https://github.com/jhaizhou-ops/S2Arm/releases/tag/v" + version) }

struct UpdatePopupView: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }
    private var popup: [String: Any] { model.updatePopup ?? [:] }
    private var version: String { popup["version"] as? String ?? "" }
    private var notes: [String: Any] { popup["notes"] as? [String: Any] ?? [:] }
    private var after: Bool { popup["kind"] as? String == "afterUpdate" }
    private var isEnglish: Bool { language == "en" }
    private var isWorking: Bool { if case .working = model.updateState { return true }; return false }
    private var isReady: Bool { model.updateState == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if after { afterBody } else { updateBody }
        }
        .padding(LauncherTheme.Space.page)
        .launcherSheet(.form, height: nil)
        .accessibilityIdentifier(after ? "update.after" : "update.popup")
    }

    private var updateBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            LauncherHeadingLine {
                Text("S2Arm v" + version).font(LauncherTheme.TypeStyle.title)
            } subtitle: {
                HStack(alignment: .firstTextBaseline, spacing: LauncherTheme.Space.small) {
                    Text(t("update.popup.kicker")).font(LauncherTheme.TypeStyle.section).foregroundStyle(LauncherPalette.cream.opacity(0.8))
                        .help(t("update.popup.kicker"))
                    Text(t("update.popup.meta")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).help(t("update.popup.meta"))
                }
            }
            let sections = notes["sections"] as? [[String: Any]] ?? []
            if sections.isEmpty {
                Text(t("update.popup.noNotes")).font(LauncherTheme.TypeStyle.body).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section["title"] as? String ?? "").font(.manrope(14, .semibold)).foregroundStyle(LauncherPalette.cream)
                                bullets(section["items"] as? [[String: Any]] ?? [])
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            if case .working(let id, let percent) = model.updateState {
                VStack(alignment: .leading, spacing: 6) {
                    LauncherProgressBar(value: percent.map { Double($0) / 100.0 }, height: 6)
                    Text(t(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)"))
                        .font(LauncherTheme.TypeStyle.detail).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if case .failed(let code) = model.updateState {
                Text(t("update.error." + code)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gate = model.updateGate {   // 草图④：点了「现在更新并重启」但有局 / 任务在跑，先拦下、说清，弹窗不关
                VStack(alignment: .leading, spacing: 4) {
                    Text(t(gate)).font(.manrope(14, .bold))
                    Text(t(gate + ".body")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.building.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("update.gate")
            }
            HStack(spacing: 10) {
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream).controllerShortcut(.secondary)
                }
                Spacer()
                if !isWorking {
                    Button(t("update.popup.skip")) { model.skipUpdateVersion() }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle())
                        .accessibilityIdentifier("update.popup.skip")
                }
                Button(t("update.popup.later")) { model.closeUpdatePopup() }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("update.popup.later").controllerShortcut(.back)
                Button(primaryActionTitle) {
                    if isReady { model.restartToUpdate() }
                    else { model.downloadUpdate() }
                }
                .controllerButtonStyle(LauncherPrimaryButtonStyle()).disabled(isWorking)
                .accessibilityIdentifier("update.popup.now").controllerShortcut(.rightTrigger)
            }
        }
    }

    private var primaryActionTitle: String {
        if isReady { return t("update.popup.now") }
        if isWorking { return t("update.settings.btn.downloading") }
        if case .failed = model.updateState { return t("update.popup.retryDownload") }
        return t("update.popup.download")
    }

    private var afterBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(LauncherPalette.ready)
                LauncherSheetHeading(t("update.after.title").replacingOccurrences(of: "{0}", with: version), subtitle: t("update.after.lead"))
            }
            bullets(notes["highlights"] as? [[String: Any]] ?? [])
            HStack {
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream).controllerShortcut(.secondary)
                }
                Spacer()
                Button(t("update.after.ok")) { model.closeUpdatePopup() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).accessibilityIdentifier("update.after.ok").controllerShortcut(.rightTrigger, .back)
            }
        }
    }

    private func bullets(_ items: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(noteText(item, language)).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

/// 「消息」面板：公告（最新在前）+ 更新说明。打开即看过最新那条公告（model.openMessages）
struct MessagesPanel: View {
    @ObservedObject var model: S2ArmLauncherModel
    let language: String

    private func t(_ id: String) -> String { BackendText.launcherText(id, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("messages.title")).font(LauncherTheme.TypeStyle.panelTitle).padding(.horizontal, 4).padding(.bottom, 6)
            if model.messages.isEmpty {
                Text(t("messages.empty")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).padding(4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, message in row(message) }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(LauncherTheme.Metrics.cardInset).frame(width: 440)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("messages.panel")
    }

    @ViewBuilder private func row(_ m: [String: Any]) -> some View {
        let unread = m["unread"] as? Bool == true
        VStack(alignment: .leading, spacing: 6) {
            if m["kind"] as? String == "update" {
                let version = m["version"] as? String ?? ""
                Text(t("messages.kind.update").replacingOccurrences(of: "{0}", with: version) + " · " + t(m["installed"] as? Bool == true ? "messages.installed" : "messages.available"))
                    .font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                let notes = m["notes"] as? [String: Any] ?? [:]
                let items = (notes["highlights"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (notes["sections"] as? [[String: Any]] ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Text("• " + noteText(item, language)).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true)
                }
                if let link = releasePage(version) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("update.popup.fullLog")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            } else {
                HStack(spacing: 8) {
                    if unread { Circle().fill(LauncherPalette.danger).frame(width: 7, height: 7) }
                    Text(t(m["level"] as? String == "important" ? "messages.kind.important" : "messages.kind.notice")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                }
                Text(LauncherCopy.note((m["text"] as? [String: String])?[language] ?? ""))
                    .font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let link = (m["url"] as? String).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: { Text(t("notice.details")).font(LauncherTheme.TypeStyle.detail).underline() }
                        .controllerButtonStyle(.plain).foregroundStyle(LauncherPalette.cream)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(unread ? 0.07 : 0.0), in: RoundedRectangle(cornerRadius: 12))
    }
}
