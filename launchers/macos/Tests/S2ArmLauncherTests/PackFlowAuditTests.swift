import XCTest
@testable import S2ArmLauncher

// 出包 / 装机任务状态（审计 11-01 P1-1 P2-1 P2-7）：重试接着做失败的那一步；一包即完整（两段式 维护者 10-27 否，启动器侧 11-01 删）
@MainActor final class PackFlowAuditTests: XCTestCase {
    private func task(_ id: String, _ op: String, _ state: String, game: String = "0100535012974000", started: Double, ended: Double? = nil) -> TaskRecord {
        var t = TaskRecord(id:id, operation:op, state:state, gameId:game, started:started); t.ended = ended; return t
    }

    func testRetryResumesTheFailedStep() {
        XCTAssertEqual(Store.retryRoute(task("a", "install", "failed", started:1)), .install, "装到 iPhone 失败：只重签重装，不从头编译")
        XCTAssertEqual(Store.retryRoute(task("c", "ipa", "failed", started:1)), .ipa)
        XCTAssertEqual(Store.retryRoute(task("d", "launch", "failed", started:1)), .launch)
        XCTAssertEqual(Store.retryRoute(task("e", "saveRestore", "failed", started:1)), .saveManager)
        XCTAssertEqual(Store.retryRoute(task("f", "build", "failed", started:1)), .build)
    }

    func testAdoptedJobsKeepTheExecutionSlot() {   // 审计 P1-75：接管仍活着的作业，正常起时占执行位的照样占
        for op in ["build", "ipa", "install", "launch", "saveRestore", "saveBackup", "platformBuild", "prepareEngine"] { XCTAssertTrue(Store.occupiesExecution(op), op) }
        for op in ["import", "keys", "catalog", "clean", "remove", "diagnostics"] { XCTAssertFalse(Store.occupiesExecution(op), op) }
    }

    func testInstallSentenceFollowsPushedFiles() {   // 审计 18:00 P1-58：按这次实际推了几个文件写
        XCTAssertTrue(Store.packPushedClause(12).contains("12"))
        XCTAssertEqual(Store.packPushedClause(0), L("，资源包已是最新（没有要推的文件）"))
        XCTAssertEqual(Store.packPushedClause(nil), "")
        XCTAssertFalse(Store.packPushedClause(3).contains("拷好了"))
    }

    func testNoticeSaysOnlyWhatIsDone() {
        XCTAssertTrue(Store.ipaDoneNotice().hasPrefix("iPhone 包已出好。"))
        XCTAssertFalse(Store.ipaDoneNotice().contains("首段"), "一包即完整：没有首段 / 补充包")
        // 装机主路还没真机验证：出完包的提示与装机步骤页同一口径，不说「就能装上」
        XCTAssertFalse(InstallGuideView.xcodeInstallVerified)
        XCTAssertTrue(Store.ipaDoneNotice().contains("还在真机验证"))
        XCTAssertFalse(Store.ipaDoneNotice().contains("就能装上"))
    }

    func testLatestFailedIpaHidesTheCompletionHero() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        UserDefaults.standard.removeObject(forKey:"tasks.completionHeroDismissed")
        let store = Store(privateRoot:temp)
        let first = task("ipa1", "ipa", "completed", started:10, ended:100)
        store.tasks = [first]
        XCTAssertEqual(store.completionHeroTask?.id, "ipa1")
        store.tasks = [first, task("ipa2", "ipa", "failed", started:110, ended:130)]
        XCTAssertNil(store.completionHeroTask, "最近一次出包失败：不给完成页")
    }

    func testNewTextsAreTranslated() {
        let previous = Localization.preference; defer { Localization.preference = previous }
        Localization.preference = .english
        for text in [Store.dotnetRecheckFailed, Store.ipaDoneNotice()] {
            XCTAssertNotEqual(L(text), text, "漏译会原样显示中文：\(text)")
        }
    }
}

/// 审计 18:00 P2-36：设置里一键安装复查过了才写「已安装」，没过写失败原因
@MainActor final class ToolchainInstallNoticeTests: XCTestCase {
    func testInstalledOnlyAfterRecheckPasses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-toolchain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        store.checks = [ToolCheck(name: ".NET SDK", ok: false, message: "没装上", action: "installDotnet")]
        store.toolchainInstalled("installDotnet", ".NET SDK 已安装。", Store.dotnetInstallRecheckFailed)
        XCTAssertEqual(store.error, Store.dotnetInstallRecheckFailed); XCTAssertNotEqual(store.notice, ".NET SDK 已安装。")
        store.error = nil
        store.checks = [ToolCheck(name: ".NET SDK", ok: true, message: "好", action: "installDotnet")]
        store.toolchainInstalled("installDotnet", ".NET SDK 已安装。", Store.dotnetInstallRecheckFailed)
        XCTAssertEqual(store.notice, ".NET SDK 已安装。"); XCTAssertNil(store.error)
    }
}
