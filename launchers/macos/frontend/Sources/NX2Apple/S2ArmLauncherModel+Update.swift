// S2Arm（不是上游文件）：覆盖更新（11-08 维护者）。v0.3.10 起下载、验签、替换、回滚、重启都交给 Sparkle 2（SparkleUpdate.swift），这里只管状态和按钮；
// 有没有新版、更新说明、公告仍由 pack/jobs/updater.py inbox 给。
// 玩家的数据不在 App 里；出包等作业进行中不提示、不替换。
import AppKit
import Foundation
import S2ArmAppleAdapter

enum UpdateState: Equatable {
    case idle
    case working(String, Int?)   // 文案号，百分比
    case ready
    case failed(String)          // 错误码
}

extension S2ArmLauncherModel {
    /// 自动更新失败时「打开下载页」：官方下载页（用系统浏览器打开），手动下载新版
    static let downloadPage = URL(string: "https://jhaizhou-ops.github.io/S2Arm/")!

    /// 控制口用：{state, detail, percent}。
    var updateStatus: [String: Any] {
        switch updateState {
        case .idle: return ["state": "idle"]
        case .working(let id, let percent): return ["state": "working", "detail": id, "percent": percent ?? NSNull()]
        case .ready: return ["state": "ready", "detail": sparkleUpdate.foundVersion ?? "", "via": "sparkle"]
        case .failed(let code): return ["state": "failed", "detail": code, "reason": updateFailure ?? ""]
        }
    }

    private var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// 启动时：把 Sparkle 起起来（上一次替换的收尾、换好后的确认都在它里面）
    func finishPendingUpdate() {
        _ = sparkleUpdate
    }

    /// 启动时一次（或手动检查）：查版本 + 取公告，按「永远只给最新一期」算出弹窗 / 横幅 / 消息（pack/jobs/updater.py inbox）。
    /// - 自动检查更新开 + 自动下载更新开：后台先下载，下好验签后才弹更新窗口让用户确认重启。
    /// - 自动检查更新开 + 自动下载更新关（默认）：查到新版立刻弹窗显示更新内容，由用户选择「下载更新」或「跳过此版本」，绝不后台偷下。
    /// - 自动检查更新关：启动只拉公告/消息，不自动弹更新窗也不自动下载（用户可在设置里手动点检查更新）。
    func loadInbox(manual: Bool = false) {
        if manual { updateCheckFeedback = "checking" }
        Task {
            guard let result = await provider.client.inbox(current: currentVersion) else {
                if manual { updateCheckFeedback = "failed" }
                return
            }
            notice = result["banner"] as? [String: Any]
            messages = result["messages"] as? [[String: Any]] ?? []
            unreadMessages = result["unread"] as? Int ?? 0
            let popup = result["popup"] as? [String: Any]
            let update = result["update"] as? [String: Any]
            let hasUpdate = update?["available"] as? Bool == true
            let version = update?["version"] as? String

            if manual {
                if hasUpdate, let update, let version {
                    availableUpdate = update
                    if skippedUpdateVersion == version { skippedUpdateVersion = nil }
                    updateCheckFeedback = "available"
                    showUpdatePopup()
                } else {
                    updateCheckFeedback = "upToDate"
                }
                return
            }

            if popup?["kind"] as? String != "update" {
                if hasUpdate, autoCheckUpdates { availableUpdate = update }
                updatePopup = popup
                return
            }

            guard autoCheckUpdates, hasUpdate, let update, let version else { return }
            availableUpdate = update
            if skippedUpdateVersion == version { return }

            if autoDownloadUpdates {
                if sparkleUpdate.readyToInstall {
                    showUpdatePopup()
                } else {
                    autoDownloadPopupPending = true
                    downloadUpdate()
                }
            } else {
                updatePopup = popup
            }
        }
    }

    /// 设置页「检查更新」按钮：主动查新版，查到就弹窗展示更新内容
    func manualCheckForUpdates() {
        loadInbox(manual: true)
    }

    /// 玩家在更新弹窗点「跳过此版本」：记下版本号并取消正在准备安装的 Sparkle 会话，以后这一版不再自动弹窗或自动下载
    func skipUpdateVersion() {
        let version = (updatePopup?["version"] as? String) ?? (availableUpdate?["version"] as? String)
        updateGate = nil
        autoDownloadPopupPending = false
        installWhenReady = false
        updatePopup = nil
        sparkleUpdate.cancelOrSkipReadyUpdate()
        if case .working = updateState { updateState = .idle }
        if case .ready = updateState { updateState = .idle }
        if let version, !version.isEmpty {
            skippedUpdateVersion = version
            Task { await provider.client.inboxSeen(update: version) }
        }
    }

    /// 后台自动下载完成回调（仅自动检查 + 自动下载模式下自动弹窗）
    func onAutoDownloadReady() {
        guard autoDownloadPopupPending else { return }
        autoDownloadPopupPending = false
        showUpdatePopup()
    }

    /// 玩家点 ×：当场收起，再记下这条（比它旧的也都算看过）
    func dismissNotice() {
        guard let id = notice?["id"] as? String else { return }
        notice = nil
        if (messages.first?["id"] as? String) == id { unreadMessages = 0 }
        Task { await provider.client.inboxSeen(notice: id) }
    }

    /// 关掉弹窗（以后再说 / 知道了 / 新功能大窗的关闭、跳过、去出包）：这一版 / 这一期不再弹
    func closeUpdatePopup() {
        updateGate = nil
        if updatePopup?["kind"] as? String == "feature", let id = updatePopup?["id"] as? String {
            updatePopup = nil
            Task { await provider.client.inboxSeen(feature: id) }
            return
        }
        guard let popup = updatePopup, let version = popup["version"] as? String else { updatePopup = nil; return }
        updatePopup = nil
        let after = popup["kind"] as? String == "afterUpdate"
        Task { await provider.client.inboxSeen(update: after ? nil : version, after: after ? version : nil) }
    }

    /// 新功能大窗最后一页「去出包」：记看过、回游戏库；库里还没有游戏就直接打开「添加游戏」
    func closeFeatureAndExport() {
        closeUpdatePopup()
        showEnvironment = false; exportFor = nil
        if games.isEmpty { showAddGames = true }
    }

    /// 顶栏「有新版 vX」：回到弹窗①
    func showUpdatePopup() {
        guard let update = availableUpdate, let version = update["version"] as? String else { return }
        updatePopup = ["kind": "update", "version": version, "notes": update["notes"] ?? NSNull()]
    }

    /// 打开「消息」：看过最新那条公告，未读清零（更旧的本来就不算未读）
    func openMessages() {
        unreadMessages = 0
        if let id = messages.first(where: { $0["kind"] as? String == "notice" })?["id"] as? String {
            Task { await provider.client.inboxSeen(notice: id) }
        }
    }

    /// 下载新版：交给 Sparkle（SparkleUpdate）查 appcast、下载、验签；进度映射到 updateState
    func downloadUpdate() {
        switch updateState { case .idle, .failed: break; default: return }
        updateFailure = nil
        updateState = .working("update.downloading", 0)
        saveUpdateNotes()
        sparkleUpdate.checkAndDownload()
    }

    /// 换上新版后第一次打开要弹「这版更新了什么」（updater.py inbox 读 updates/notes/<版本>.json）：说明随查到的新版记在本机，换完不再联网
    private func saveUpdateNotes() {
        guard let update = availableUpdate, let version = update["version"] as? String, let notes = update["notes"], !(notes is NSNull),
              JSONSerialization.isValidJSONObject(notes), let data = try? JSONSerialization.data(withJSONObject: notes) else { return }
        let folder = provider.client.environment.privateRoot.appendingPathComponent("updates/notes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(version).json"))
    }

    /// 只有玩家点了才换版。有局 / 任务在跑：先拦下说清（草图④：前置检查，不进换版）。还没下：先下，下好（SparkleUpdate.showReady）接着换。
    ///   替换、回滚、重启都由 Sparkle 做
    func restartToUpdate() {
        if busy { updateGate = session?.kind == .play ? "update.gate.playing" : "update.gate.busy"; installWhenReady = false; return }
        guard sparkleUpdate.readyToInstall else {
            installWhenReady = true
            downloadUpdate()
            return
        }
        installWhenReady = false
        updatePopup = nil
        sparkleUpdate.installNow()
    }
}

/// 退出 App，先等窗口上的 sheet 摘掉。窗口挂着 sheet 时 `NSApp.terminate` 被 AppKit 忽略、不报错（macOS 27.0.1 实测）：
/// 更新弹窗里点「现在更新」，替换进程起来了、S2Arm 没退，等满 120 秒记 update_app_busy，界面上什么都没发生。
/// 每 `pollSeconds` 看一次：没有 sheet 了就退；到 `forcePolls` 次还挂着就主动摘；到 `maxPolls` 次照旧调一次退出、不再等。
@MainActor enum QuitAfterSheets {
    static let pollSeconds = 0.05, forcePolls = 20, maxPolls = 100

    static func run(windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }, polls: Int = 0,
                    terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        let attached = windows().filter { $0.attachedSheet != nil }
        if attached.isEmpty || polls >= maxPolls { terminate(); return }
        if polls >= forcePolls { for window in attached { if let sheet = window.attachedSheet { window.endSheet(sheet) } } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            run(windows: windows, polls: polls + 1, terminate: terminate)
        }
    }
}
