// S2Arm（不是上游文件）：环境检查页（preflight 作业的清单）。没过的在前、按组放进 NXLauncher 的卡片（CardGroup / CardRow），
// 每项给一键处理：缺 Xcode → 去 App Store 安装；装了没打开过 → 打开 Xcode；缺 Metal 组件 → 一键下载（downloadMetal 作业）；缺 iOS 平台组件 → 一键下载（downloadIosPlatform 作业，约 8 GB）；
// 缺 .NET SDK → 一键安装（installDotnet 作业）；游戏库在云盘同步目录 / 不支持的盘格式上 → 换游戏库（选目录 → setup 作业）。
// 作业跑在作业页，做完自动重新检查。通过的折起来。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct EnvironmentView: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    var onOpenSpace: (() -> Void)? = nil
    @State private var showPassed = false

    /// 组的顺序同旧启动器 ToolChecks。
    private static let groups = ["system", "apple", "engine", "bundled", "storage"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: LauncherTheme.Space.large) {
                LauncherSheetHeading(s("nav.settings"), subtitle: LauncherCopy.note(summary))
                if model.checking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.top, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section)
            if let error = model.environmentError ?? (model.inlineFailure?.kind == .keys ? model.inlineFailure?.message : nil) {
                Text(loc.backend(error)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.medium)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: LauncherTheme.Space.section) {
                    // 界面语言（原在顶栏，入口整理收进设置）：一键切到另一种，当场生效、记住选择
                    CardGroup(s("settings.language")) {
                        // 跟随系统 / 简体中文 / English：选了某种就记住（以后不再跟系统），选「跟随系统」回到按系统首选语言（11-13）
                        CardRow(s("settings.language"), detail: Lang.saved == nil ? loc.t("settings.language.system") + " · " + loc.lang.name : loc.lang.name) {
                            LauncherDropdown(options: [("", loc.t("settings.language.system"))] + Lang.all.map { ($0.code, $0.name) },
                                             selection: Lang.saved?.code ?? "", label: s("settings.language")) { loc.choose($0) }
                                .controllerID("settings.language")
                        }
                    }
                    // 存放位置（社区贡献者补丁 #10）：游戏库、iPhone 包、磁盘空间集中在这一处；单款游戏放在哪看出包页的「存放位置」
                    CardGroup(s("settings.locations")) {
                        let library = model.provider.client.environment.library
                        CardRow(s("settings.locations.library"), detail: loc.t("s2arm.env.library.detail"), detail2: library, stacked: true) {
                            LauncherRowActions {
                                Button(s("settings.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: library)) }
                                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(library.isEmpty)
                                    .controllerID("settings.library.open")
                                Button(loc.t("s2arm.env.library.change")) { chooseLibrary() }
                                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
                                    .controllerID("settings.library.change")
                            }
                        }
                        CardDivider()
                        let ipa = (library as NSString).appendingPathComponent("S2Arm.ipa")   // 出 iPhone 包时组在游戏库根
                        let ipaReady = !library.isEmpty && FileManager.default.fileExists(atPath: ipa)
                        CardRow(s("settings.locations.ipa"), detail: ipaReady ? "" : s("settings.locations.ipa_none"), detail2: ipaReady ? ipa : "") {
                            if ipaReady { Button(loc.t("s2arm.export.revealIpa")) { model.revealIpa(ipa) }.controllerButtonStyle(LauncherSecondaryButtonStyle()) }
                        }
                        CardDivider()
                        CardRow(s("settings.locations.space")) {
                            Button(s("storage.open")) {
                                onOpenSpace?()
                                model.showEnvironment = false
                                let target = model.selectedID ?? model.games.first?.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.spaceRequest = target }
                            }
                                .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.games.isEmpty)
                        }
                    }
                    // 密钥：状态 + 导入（同 Windows 设置页；11-14 体验梳理：原先密钥就绪后 Mac 上没有地方换一份）
                    CardGroup(s("settings.keys")) {
                        CardRow(s("settings.keys"), detail: model.keysReady == true ? s("welcome.step.keys.done") : s("welcome.step.keys.title")) {
                            Button(s("library.import_keys")) { chooseKeys() }
                                .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy)
                                .controllerID("settings.keys.import")
                        }
                    }
                    InstallModeCard(model: model)   // 装到 iPhone 的方式（v0.3.0：签名 / 安装入口收在这一处）
                    // 主屏小组件（11-16）：装到 iPhone / 更新 / 导出时带不带 iPhone 桌面的游戏机小组件；缺省开，关掉后请求里带 widget: false
                    CardGroup(loc.t("s2arm.env.widget.group")) {
                        CardRow(loc.t("s2arm.env.widget.title"), detail: model.homeWidgetError.map(loc.backend) ?? loc.t("s2arm.env.widget.detail")) {
                            Toggle("", isOn: Binding(get: { model.homeWidget }, set: { model.setHomeWidget($0) }))
                                .toggleStyle(LauncherSwitchStyle()).labelsHidden()
                                .accessibilityLabel(loc.t("s2arm.env.widget.title"))
                                .accessibilityIdentifier("env.homeWidget")
                        }
                    }
                    let failing = model.checks.filter { !$0.ok }
                    ForEach(ordered(failing), id: \.self) { group in
                        let items = failing.filter { groupOf($0) == group }
                        CardGroup(groupName(group)) {
                            ForEach(items) { check in
                                row(check)
                                if check.id != items.last?.id { CardDivider() }
                            }
                        }
                    }
                    // iCloud 存档同步（S2ArmLauncherModel+CloudSaves）：选 iCloud 云盘里的文件夹，iPhone / iPad 上选同一个
                    CardGroup(loc.t("s2arm.env.cloud.group")) {
                        CardRow(loc.t("s2arm.env.cloud.title"), detail: loc.t(model.cloudFolder == nil ? "s2arm.env.cloud.off" : "s2arm.env.cloud.on"),
                                detail2: model.cloudFolder?.path ?? "") {
                            if model.cloudFolder != nil {
                                LauncherRowActions {
                                    Button(loc.t("s2arm.env.cloud.turnOff")) { do { try model.setCloudFolder(nil) } catch { model.reportFailure("s2arm.fail.cloudFolder", error) } }
                                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("env.cloud.off")
                                    Button(loc.t("s2arm.env.library.change")) { chooseCloudFolder() }
                                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("env.cloud.choose")
                                }
                            } else {
                                Button(loc.t("s2arm.env.cloud.choose")) { chooseCloudFolder() }
                                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("env.cloud.choose")
                            }
                        }
                    }
                    // 允许 AI 操作 S2Arm（本机控制口，S2ArmControl）：玩家用自己的 AI 照 App 自带的操作手册做导入 → 出包 → 装机（维护者 10-23）
                    CardGroup(loc.t("s2arm.env.ai.group")) {
                        CardRow(loc.t("s2arm.env.ai.title"), detail: model.aiControlError.map(loc.backend) ?? loc.t("s2arm.env.ai.detail")) {
                            Toggle("", isOn: Binding(get: { model.aiControl }, set: { model.setAIControl($0) }))
                                .toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(ControlPort.forced)
                                .accessibilityLabel(loc.t("s2arm.env.ai.title"))
                                .accessibilityIdentifier("env.aiControl")
                        }
                    }
                    // 软件更新（自动检查 + 自动下载 + 手动检查按钮，与顶栏手动更新入口对照）
                    updateSettingsCard
                    let passed = model.checks.filter(\.ok)
                    if !passed.isEmpty {
                        CardGroup(loc.t("s2arm.env.passedGroup")) {
                            CardDisclosure(String(format: loc.t("s2arm.env.passed"), passed.count), isOpen: showPassed) { showPassed.toggle() }
                            if showPassed {
                                ForEach(passed) { check in
                                    CardDivider()
                                    row(check)
                                }
                            }
                        }
                    }
                    // 版本号（三端同号：Windows 启动器、iPhone 上的 S2Arm 显示同一个，装机时写进 iPhone 那份）
                    Text(verbatim: "S2Arm " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"))
                        .font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("env.version")
                }
                .padding(.horizontal, LauncherTheme.Space.page).padding(.bottom, LauncherTheme.Space.section)
            }
            LauncherSheetFooter {
                Text(loc.t("s2arm.env.note")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Button(loc.t("s2arm.env.recheck")) { model.checkEnvironment() }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.checking || model.busy).controllerShortcut(.secondary)
                Button(loc.t("launch.done")) { dismiss() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .controllerID("settings.done").controllerShortcut(.rightTrigger, .back)
            }
        }
        .onAppear { if model.checks.isEmpty { model.checkEnvironment() } }
        .onChange(of: model.updatePopup != nil) { hasPopup in
            if hasPopup { model.showEnvironment = false }
        }
        .onDisappear {
            if model.inlineFailure?.kind == .keys { model.clearInlineFailure() }
            if model.showKeys { model.showKeys = false }
        }
        .launcherSheet()
        .onExitCommand { dismiss() }
    }

    /// 顶部口径要说清是哪一种「齐了」：只差打 iPhone 包的项时不能写「都齐了」（11-08：iOS 平台组件红着、顶部却全绿）。
    private var summary: String {
        switch model.environmentState {
        case .unknown: return loc.t("s2arm.env.checking")
        case .ready: return loc.t("s2arm.env.ready")
        case .readyMac:
            let left = model.checks.filter { !$0.ok && $0.required(for: "ipa") }.count
            return String(format: loc.t(left == 1 ? "s2arm.env.readyMacOne" : "s2arm.env.readyMac"), left)
        case .missing: return loc.t("s2arm.env.missing")
        }
    }

    private func groupOf(_ check: ToolCheck) -> String { Self.groups.contains(check.group) ? check.group : "system" }
    private func ordered(_ checks: [ToolCheck]) -> [String] { Self.groups.filter { g in checks.contains { groupOf($0) == g } } }
    private func groupName(_ group: String) -> String { loc.t("s2arm.env.group." + group) }

    /// 换游戏库：选一个本机、不同步的文件夹（作业层 setup 再拦一遍云盘 / 不支持的盘格式），交给 model.changeLibrary。
    private func chooseCloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: drive.path) { panel.directoryURL = drive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.setCloudFolder(url) } catch { model.reportFailure("s2arm.fail.cloudFolder", error) }   // 剃刀 M13：失败报原因，不再停在旧值像没反应
    }

    private func chooseKeys() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "keys") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importKeys(url)
    }

    private func s(_ id: String) -> String { BackendText.launcherText(id, language: loc.lang.sharedCode) }

    @ViewBuilder private var updateSettingsCard: some View {
        let en = loc.lang.sharedCode == "en"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let foundVersion = model.availableUpdate?["version"] as? String
        let isWorking: Bool = { if case .working = model.updateState { return true }; return false }()
        let manualDetail: String = {
            if model.updateState == .ready, let v = foundVersion {
                return en ? "Version v\(v) is downloaded and ready to install" : "新版 v\(v) 已下载就绪，可重启安装"
            }
            if case .working(let id, let percent) = model.updateState {
                return s(id).replacingOccurrences(of: "{0}", with: "\(percent ?? 0)")
            }
            if model.updateCheckFeedback == "checking" {
                return en ? "Checking for updates..." : "正在检查是否有新版本..."
            }
            if let v = foundVersion {
                return en ? "New version v\(v) available" : "发现新版本 v\(v)"
            }
            if model.updateCheckFeedback == "upToDate" {
                return en ? "You are on the latest version (v\(current))" : "当前已是最新版本（v\(current)）"
            }
            if model.updateCheckFeedback == "failed" {
                return en ? "Update check failed — please verify your network" : "检查更新失败，请检查网络连接"
            }
            return en ? "Current version v\(current)" : "当前版本 v\(current)"
        }()
        let manualButtonTitle: String = {
            if model.updateState == .ready { return en ? "Update now" : "立即更新" }
            if isWorking { return en ? "Downloading..." : "下载中..." }
            if model.updateCheckFeedback == "checking" { return en ? "Checking..." : "检查中..." }
            if foundVersion != nil { return en ? "View update" : "查看新版" }
            return en ? "Check now" : "检查更新"
        }()

        CardGroup(en ? "Software Updates" : "软件更新") {
            CardRow(en ? "Check for updates automatically" : "自动检查更新",
                    detail: en ? "Check for new versions when S2Arm opens" : "启动时自动检查是否有新版本") {
                Toggle("", isOn: $model.autoCheckUpdates)
                    .toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .accessibilityLabel(en ? "Check for updates automatically" : "自动检查更新")
                    .accessibilityIdentifier("settings.updates.autoCheck")
            }
            CardDivider()
            CardRow(en ? "Download updates automatically" : "自动下载更新",
                    detail: en ? "Download updates in the background and prompt once ready; when off, prompt with release notes before downloading"
                               : "开启后在后台自动下载，下载成功后弹窗提示；关闭时查到更新先弹窗展示内容，由你决定是否下载") {
                Toggle("", isOn: $model.autoDownloadUpdates)
                    .toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .disabled(!model.autoCheckUpdates)
                    .accessibilityLabel(en ? "Download updates automatically" : "自动下载更新")
                    .accessibilityIdentifier("settings.updates.autoDownload")
            }
            CardDivider()
            CardRow(en ? "Manual check" : "手动检查更新", detail: manualDetail) {
                Button(manualButtonTitle) {
                    if model.updateState == .ready || model.availableUpdate != nil {
                        model.showUpdatePopup()
                        model.showEnvironment = false
                    } else {
                        model.manualCheckForUpdates()
                    }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .disabled(isWorking || model.updateCheckFeedback == "checking")
                .accessibilityIdentifier("settings.updates.check")
            }
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = loc.t("s2arm.library.choosePanel")
        panel.prompt = loc.t("s2arm.library.choosePrompt")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 有游戏、选的是空文件夹才问；已有游戏库或含旧产物的文件夹由作业层直接打开 / 认领
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        // 系统自动生成的文件不算数：同作业层 layout.OS_JUNK / OS_JUNK_PREFIX（三端一份，tests/os_junk_sync_test.sh 核一致）
        let osJunk: Set<String> = [".DS_Store", "desktop.ini", "Thumbs.db"]
        guard !model.games.isEmpty, contents.allSatisfy({ osJunk.contains($0) || $0.hasPrefix("._") }) else { model.changeLibrary(to: url); return }
        let alert = NSAlert()
        alert.messageText = loc.t("s2arm.library.moveTitle")
        alert.informativeText = loc.t("s2arm.library.moveBody")
        alert.addButton(withTitle: loc.t("s2arm.library.moveConfirm"))
        alert.addButton(withTitle: loc.t("s2arm.library.moveEmpty"))
        alert.addButton(withTitle: loc.t("fail.confirm.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.changeLibrary(to: url, move: true)
        case .alertSecondButtonReturn: model.changeLibrary(to: url)
        default: break
        }
    }

    /// 检查项的名字与说明是作业层的定句（中文），按界面语言显示（loc.backend）。
    @ViewBuilder private func row(_ check: ToolCheck) -> some View {
        CardRow(loc.backend(check.name), detail: check.ok ? "" : loc.backend(check.message), dot: check.ok ? LauncherPalette.ready : LauncherPalette.danger) {
            if !check.ok, let action = check.action, case let key = "s2arm.env.action." + action, loc.t(key) != key {
                Button(loc.t(key)) {
                    if model.provider.environment.repairStep(for: action) == .chooseLibrary { chooseLibrary() } else { model.repair(check) }
                }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle()).disabled(model.busy || model.checking)
            }
        }
    }
}
