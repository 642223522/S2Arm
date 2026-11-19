// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import Foundation

@MainActor final class SimulatedUpdateDriver: ObservableObject, LauncherUpdateDriver {
    static let enabledKey = "S2AUpdateSimulate"

    /// 模拟只给没有更新源的构建（本地 / 自测拷贝）用；带 SUFeedURL 的发行版即使偏好开着也走正式更新、App 菜单不出「模拟更新」
    nonisolated static func isAllowed(preference: Bool, info: [String: Any]?) -> Bool {
        preference && ((info?["SUFeedURL"] as? String) ?? "").isEmpty
    }
    private static let version = "9.9.9"
    private static let totalBytes: UInt64 = 138_000_000

    enum CheckResult: String, CaseIterable {
        case available = "有新版"
        case upToDate = "已是最新"
        case network = "失敗：update_network"
        case rateLimited = "失敗：update_rate_limited"
        case server = "失敗：update_server"

        var error: String? {
            switch self {
            case .available, .upToDate: return nil
            case .network: return "update_network"
            case .rateLimited: return "update_rate_limited"
            case .server: return "update_server"
            }
        }
    }

    enum DownloadResult: String, CaseIterable {
        case success = "成功"
        case interrupted = "在 40% 失敗：update_download_failed"
        case signature = "驗簽失敗：update_bad_signature"
        case diskFull = "磁碟已滿：update_disk_full"
        case noPermission = "無寫入權限：update_no_permission"

        var error: String? {
            switch self {
            case .success: return nil
            case .interrupted: return "update_download_failed"
            case .signature: return "update_bad_signature"
            case .diskFull: return "update_disk_full"
            case .noPermission: return "update_no_permission"
            }
        }
    }

    enum Speed: Double, CaseIterable {
        case fast = 5
        case normal = 20
        case slow = 60

        var title: String {
            switch self {
            case .fast: return "快（5 秒）"
            case .normal: return "正常（20 秒）"
            case .slow: return "慢（60 秒）"
            }
        }
    }

    private enum Key {
        static let checkResult = "S2AUpdateSimulate.checkResult"
        static let downloadResult = "S2AUpdateSimulate.downloadResult"
        static let speed = "S2AUpdateSimulate.speed"
        static let busy = "S2AUpdateSimulate.busy"
        static let prompted = "S2AUpdateSimulate.prompted"
        static let installed = "S2AUpdateSimulate.installed"
        static let showAfterUpdate = "S2AUpdateSimulate.showAfterUpdate"
    }

    @Published var checkResult: CheckResult {
        didSet { defaults.set(checkResult.rawValue, forKey: Key.checkResult) }
    }
    @Published var downloadResult: DownloadResult {
        didSet { defaults.set(downloadResult.rawValue, forKey: Key.downloadResult) }
    }
    @Published var speed: Speed {
        didSet { defaults.set(speed.rawValue, forKey: Key.speed) }
    }
    @Published var pretendBusy: Bool {
        didSet { defaults.set(pretendBusy, forKey: Key.busy) }
    }
    private(set) var downloadBytes: (received: UInt64, expected: UInt64) = (0, 0)
    private(set) var readyToInstall = false
    private(set) var downloadTask: Task<Void, Never>?
    private weak var model: S2ArmLauncherModel?
    private let defaults: UserDefaults
    private let sleep: (Double) async throws -> Void

    init(model: S2ArmLauncherModel, defaults: UserDefaults,
         sleep: @escaping (Double) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.model = model
        self.defaults = defaults
        self.sleep = sleep
        checkResult = CheckResult(rawValue: defaults.string(forKey: Key.checkResult) ?? "") ?? .available
        downloadResult = DownloadResult(rawValue: defaults.string(forKey: Key.downloadResult) ?? "") ?? .success
        speed = Speed(rawValue: defaults.double(forKey: Key.speed)) ?? .normal
        pretendBusy = defaults.bool(forKey: Key.busy)
    }

    private var offer: [String: Any] {
        ["available": true, "version": Self.version, "notes": Self.notes]
    }

    func check(current: String, fresh: Bool) async -> [String: Any]? {
        let result = checkResult
        do { try await sleep(1.5) } catch { return nil }
        if let error = result.error { return ["available": false, "error": error] }
        if defaults.bool(forKey: Key.installed) { return ["available": false, "version": Self.version] }
        if result == .upToDate { return ["available": false] }
        return offer
    }

    func simulateStartupCheck(failed: Bool) {
        guard let model else { return }
        if failed {
            model.applyStartupUpdate(["update": ["available": false, "error": "update_network"]])
        } else if !defaults.bool(forKey: Key.installed) {
            var inbox: [String: Any] = ["update": offer]
            if !defaults.bool(forKey: Key.prompted) {
                inbox["popup"] = ["kind": "update", "version": Self.version, "notes": Self.notes]
            }
            model.applyStartupUpdate(inbox)
        }
    }

    func startDownload() {
        if let model, model.availableUpdate == nil { model.availableUpdate = offer }
        let result = downloadResult
        let seconds = speed.rawValue
        readyToInstall = false
        downloadBytes = (0, Self.totalBytes)
        downloadTask = Task { [weak self] in
            await self?.simulateDownload(result, seconds: seconds)
        }
    }

    private func simulateDownload(_ result: DownloadResult, seconds: Double) async {
        defer { if !Task.isCancelled { downloadTask = nil } }
        do {
            let finalPercent = result == .interrupted ? 40 : 100
            for percent in 0...finalPercent {
                if percent > 0 { try await sleep(seconds / 100) }
                try Task.checkCancellation()
                downloadBytes.received = Self.totalBytes * UInt64(percent) / 100
                model?.updateState = .working("update.downloading", percent)
            }
            if result == .interrupted { failDownload(result); return }

            model?.updateState = .working("update.verifying", nil)
            try await sleep(0.6)
            try Task.checkCancellation()
            if result == .signature { failDownload(result); return }

            model?.updateState = .working("update.unpacking", nil)
            try await sleep(0.6)
            try Task.checkCancellation()
            if result.error != nil { failDownload(result); return }

            readyToInstall = true
            model?.updateDidBecomeReady()
        } catch {
            // 重置会取消当前下载，保留重置后的状态。
        }
    }

    private func failDownload(_ result: DownloadResult) {
        guard let code = result.error else { return }
        model?.logUpdate("[Simulation] " + code)
        model?.updateState = .failed(code)
    }

    func reset() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadBytes = (0, 0)
        readyToInstall = false
        defaults.removeObject(forKey: Key.prompted)
        defaults.removeObject(forKey: Key.installed)
        defaults.removeObject(forKey: Key.showAfterUpdate)
        guard let model else { return }
        model.updateCheckTask?.cancel()
        model.updateCheckTask = nil
        model.isCheckingForUpdates = false
        model.checkError = nil
        model.updateRestarting = false
        model.updateFailure = nil
        model.updateGate = nil
        model.updatePopup = nil
        model.availableUpdate = nil
        model.updateState = .idle
    }

    func markPromptSeen() {
        defaults.set(true, forKey: Key.prompted)
    }

    func consumeAfterUpdate() -> [String: Any]? {
        guard defaults.bool(forKey: Key.showAfterUpdate) else { return nil }
        defaults.removeObject(forKey: Key.showAfterUpdate)
        return ["kind": "afterUpdate", "version": Self.version, "notes": Self.notes]
    }

    func installNow() {
        guard readyToInstall else { return }
        readyToInstall = false
        defaults.set(true, forKey: Key.installed)
        defaults.set(true, forKey: Key.showAfterUpdate)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.defaults.removeObject(forKey: Key.installed)
                    self.defaults.removeObject(forKey: Key.showAfterUpdate)
                    self.model?.logUpdate("[Simulation] " + error.localizedDescription)
                    self.model?.updateFailure = error.localizedDescription
                    self.model?.updateRestarting = false
                    self.model?.updateState = .failed("update_swap_failed")
                } else {
                    QuitAfterSheets.run()
                }
            }
        }
    }

    private static var notes: [String: Any] {
        let items = [
            ["zh-Hans": "新增应用菜单中的检查更新入口。", "en": "Check for updates from the application menu."],
            ["zh-Hans": "下载时可以关掉弹窗，从顶栏圆钮回来继续看进度。", "en": "Close the update window while the download runs and reopen it from the toolbar."],
            ["zh-Hans": "下载完成后可以选一个方便的时间重启，或者勾选下载完成后自动重启。这个选择会记住。如果下载完成时还有操作在进行，启动器会等你准备好，由你自己决定何时重启。",
             "en": "Choose a convenient time to restart once the download finishes, or let the launcher restart automatically. The launcher remembers the checkbox selection for next time. When a task is still running at the end of the download, you can finish what you are doing and restart when you are ready."],
            ["zh-Hans": "更新窗口会说明失败的原因，并提供重试和下载链接。", "en": "If an update fails, the window explains what happened and offers a retry and a download link."],
        ]
        return ["sections": [["title": "更新說明 / Release notes", "items": items]], "highlights": Array(items.prefix(2))]
    }
}
