// S2Arm（不是上游文件）：应用内更新交给 Sparkle 2（v0.3.10 维护者拍板「换」：不再修补自写的 pack/jobs/updater.py 换版，#931 / #965）。
// Sparkle 负责查 appcast、下载、EdDSA 验签、整包替换、失败回滚、重启；这里只把它的每一步映射到启动器原有的状态与按钮（UpdateState），
// 不用 Sparkle 自带窗口：玩家看到的还是「有新版 → 下载中 → 现在更新并重启」，控制口 /update 照旧能驱动。
import AppKit
import Foundation
import Sparkle

@MainActor final class SparkleUpdate: NSObject, SPUUserDriver, SPUUpdaterDelegate, LauncherUpdateDriver {
    weak var model: S2ArmLauncherModel?
    private(set) var updater: SPUUpdater!
    private var expected: UInt64 = 0, received: UInt64 = 0
    /// 下载解开好、等玩家点「现在更新并重启」时 Sparkle 给的回复
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private(set) var foundVersion: String?

    init(model: S2ArmLauncherModel) {
        self.model = model
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try updater.start() } catch { log("Sparkle 起不来：\(error.localizedDescription)") }
    }

    /// 验收 / 内部联调用的假 appcast（S2A_UPDATE_FEED），没设就用 Info.plist 的 SUFeedURL（dl.s2arm.com/appcast/mac.xml）
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["S2A_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func check(current: String, fresh: Bool) async -> [String: Any]? {
        await model?.provider.client.check(current: current, fresh: fresh)
    }

    var downloadBytes: (received: UInt64, expected: UInt64) { (received, expected) }

    func startDownload() {
        guard updater.canCheckForUpdates else {
            log("Sparkle 当前无法启动下载")
            model?.updateState = .failed("update_failed")
            return
        }
        received = 0
        expected = 0
        foundVersion = nil
        updater.checkForUpdates()
    }

    var readyToInstall: Bool { installReply != nil }

    /// 「现在更新并重启」：先摘掉窗口上的弹窗（挂着 sheet 时 NSApp.terminate 会被忽略，见 QuitAfterSheets），再让 Sparkle 退出、替换、重启
    func installNow() {
        guard let reply = installReply else { return }
        installReply = nil
        log("玩家点了更新并重启：交给 Sparkle 替换 \(foundVersion ?? "?")")
        QuitAfterSheets.run(terminate: { reply(.install) })
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 定时自动检查不开（Info.plist SUEnableAutomaticChecks = NO）：查新版走启动时的公告 / 消息，这里不再问玩家
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { model?.updateState = .working("update.downloading", nil) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundVersion = appcastItem.displayVersionString
        log("发现新版 \(appcastItem.displayVersionString)（构建号 \(appcastItem.versionString)），开始下载")
        model?.updateDownloadFound(version: appcastItem.displayVersionString)
        if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
            return
        }
        reply(.install)   // 下载：真正换版仍等玩家点
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log("没有新版：\(error.localizedDescription)")
        model?.updateState = .idle
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        // 底层错误逐层带上（#1218：2001 只说「下载更新时出现错误」，真正原因——写盘失败 / 网络 / 证书——在 NSUnderlyingError 里，原先不记、查不了）
        var chain = "", cur = ns.userInfo[NSUnderlyingErrorKey] as? NSError, depth = 0
        while let u = cur, depth < 4 {
            chain += "；底层 \(u.domain) \(u.code)：\(u.localizedDescription)"
            cur = u.userInfo[NSUnderlyingErrorKey] as? NSError; depth += 1
        }
        log("更新失败（Sparkle \(ns.domain) \(ns.code)）：\(ns.localizedDescription)\(ns.localizedFailureReason.map { "；" + $0 } ?? "")\(chain)")
        model?.updateFailure = ns.localizedDescription
        model?.updateRestarting = false
        model?.updateState = .failed(Self.updateErrorCode(ns, fetchingAppcast: foundVersion == nil))
        installReply = nil
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { expected = 0; received = 0; model?.updateState = .working("update.downloading", nil) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        model?.updateState = .working("update.downloading", expected > 0 ? Int(min(received, expected) * 100 / expected) : nil)
    }
    func showDownloadDidStartExtractingUpdate() { model?.updateState = .working("update.verifying", nil) }
    func showExtractionReceivedProgress(_ progress: Double) { model?.updateState = .working("update.unpacking", Int(min(max(progress, 0), 1) * 100)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("新版 \(foundVersion ?? "?") 已下载并验签")
        installReply = reply
        model?.updateDidBecomeReady()
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("Sparkle 正在替换（App 已退出：\(applicationTerminated)）")
        if !applicationTerminated { QuitAfterSheets.run(terminate: retryTerminatingApplication) }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("已换上新版（重启：\(relaunched)）")
        acknowledgement()
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {
        if case .working = model?.updateState { model?.updateState = .idle }
    }

    nonisolated static func updateErrorCode(_ error: NSError, fetchingAppcast: Bool = false) -> String {
        var chain = [error]
        for _ in 0..<4 {
            guard let underlying = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            chain.append(underlying)
        }
        if chain.contains(where: {
            ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
                || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
        }) { return "update_disk_full" }
        if chain.contains(where: {
            ($0.domain == NSPOSIXErrorDomain && [EACCES, EPERM, EROFS].map(Int.init).contains($0.code))
                || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError)
        }) { return "update_no_permission" }

        let isSparkle = error.domain == SUSparkleErrorDomain
        let sparkle = isSparkle ? OSStatus(exactly: error.code).flatMap(SUError.init(rawValue:)) : nil
        let isAppcast = fetchingAppcast || sparkle == .appcastError || sparkle == .appcastParseError
        for cause in chain {
            let statuses = cause.userInfo.values.compactMap { ($0 as? HTTPURLResponse)?.statusCode }
            let status = httpStatusFromSparkle(cause)
            if (statuses + [status].compactMap { $0 }).contains(where: { $0 == 404 || (500...599).contains($0) }) {
                return isAppcast ? "update_network" : "update_server"
            }
        }
        let networkErrors = [
            NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired, NSURLErrorDataNotAllowed,
        ]
        if chain.contains(where: { $0.domain == NSURLErrorDomain && networkErrors.contains($0.code) }) {
            return isAppcast ? "update_network" : "update_download_failed"
        }
        switch sparkle {
        case .appcastError, .appcastParseError: return "update_network"
        case .downloadError: return isAppcast ? "update_network" : "update_download_failed"
        case .signatureError, .validationError: return "update_bad_signature"
        case .unarchivingError: return "update_unpack_failed"
        case .installationWriteNoPermissionError, .authenticationFailure: return "update_no_permission"
        case .fileCopyFailure, .relaunchError, .installationError: return "update_swap_failed"
        default: return "update_failed"
        }
    }

    private nonisolated static func httpStatusFromSparkle(_ error: NSError) -> Int? {
        // Sparkle 2.10.1 SPUDownloader.m puts the HTTP status in this fixed suffix, without a response object.
        guard error.domain == SUSparkleErrorDomain, error.code == Int(SUError.downloadError.rawValue),
              let description = error.userInfo[NSLocalizedDescriptionKey] as? String,
              description.hasPrefix("A network error occurred while downloading "),
              let range = description.range(of: #" \([0-9]{3}\)$"#, options: .regularExpression) else { return nil }
        return Int(description[range].dropFirst(2).dropLast())
    }

    func log(_ text: String) {
        model?.logUpdate("[Sparkle] " + text)
    }
}
