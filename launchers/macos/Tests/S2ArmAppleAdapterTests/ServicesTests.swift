import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 测试用的游戏库根：写和作业层同一格式的库标记（setup 作业建库时写的就是 schema=1 / id）。
private func writeLibraryMarker(_ box: Sandbox, id: String = "lib-1") throws {
    let library = URL(fileURLWithPath: box.environment().library)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data(#"{"schema":1,"id":"\#(id)"}"#.utf8).write(to: library.appendingPathComponent(".s2arm-library.json"))
}

final class LibraryProviderTests: XCTestCase {
    func testCatalogResultBecomesGameSummaries() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "succeeded", message: "操作完成", extra: #","result":{"games":[{"id":"0100A","name":"Alpha","display":"1.2.0","cover":"/L/games/0100A/cover.jpg","ready":true,"needsPreparation":false,"compatibility":"experimental","missing":[],"sizes":{"imageMac":1,"imageIos":2,"saves":3,"cache":4,"sources":5000000000,"measured":true}},{"id":"0100B","name":"Beta","cover":"","ready":true,"needsPreparation":true},{"id":"0100C","name":"Hidden","hidden":true},{"name":"no id"}]}"#)], 0, false) }
        let done = expectation(description: "load")
        var games: [GameSummary] = []
        LibraryProvider(client: client(box, runner)).load { if case .success(let g) = $0 { games = g }; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "catalog")
        XCTAssertEqual(games.map(\.id), ["0100A", "0100B"])
        XCTAssertEqual(games[0].display, "1.2.0")
        XCTAssertEqual(games[0].cover, "/L/games/0100A/cover.jpg")
        XCTAssertNil(games[1].cover)
        XCTAssertTrue(games[0].playable)
        XCTAssertFalse(games[1].playable)   // 运行文件要重新准备
        XCTAssertEqual(games[0].sizes, GameSizes(imageMac: 1, imageIos: 2, saves: 3, cache: 4, sources: 5_000_000_000, measured: true))
        XCTAssertEqual(games[1].sizes, GameSizes(), "catalog 没给 sizes：四项 0、没量过")
    }

    func testLastKnownGamesShowBeforeTheJobAndFollowTheLibrary() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "succeeded", message: "操作完成", extra: #","result":{"games":[{"id":"0100A","name":"Alpha","display":"1.2.0","ready":true,"missing":[]}],"keys":{"ready":true},"jobs":[]}"#)], 0, false) }
        try writeLibraryMarker(box)
        let provider = LibraryProvider(client: client(box, runner))
        XCTAssertNil(provider.lastKnownGames(), "没读过：没有列表可显示")
        let done = expectation(description: "load")
        provider.load { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        let starts = runner.starts.count
        let fresh = LibraryProvider(client: client(box, runner))
        XCTAssertEqual(fresh.lastKnownGames()?.map(\.id), ["0100A"])
        XCTAssertEqual(fresh.keysReady, true)
        XCTAssertEqual(runner.starts.count, starts, "读列表不起作业")
        var other = box.environment(); other.libraryId = "another-library"
        XCTAssertNil(LibraryProvider(client: client(box, runner, env: other)).lastKnownGames(), "换了游戏库不显示旧列表")
    }


    func testLastKnownGamesIsNotShownWhenLibraryMarkerIsGone() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "succeeded", message: "操作完成", extra: #","result":{"games":[{"id":"0100A","name":"Alpha","display":"1.2.0","ready":true,"missing":[]}],"keys":{"ready":true},"jobs":[]}"#)], 0, false) }
        try writeLibraryMarker(box)
        let provider = LibraryProvider(client: client(box, runner))
        let done = expectation(description: "load")
        provider.load { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(provider.lastKnownGames()?.map(\.id), ["0100A"], "库标记在时缓存列表可用")
        try FileManager.default.removeItem(atPath: box.environment().library)
        XCTAssertNil(LibraryProvider(client: client(box, runner)).lastKnownGames(), "游戏库被删后不能显示缓存列表")
    }

    func testNoLibraryFailsWithoutStartingAJob() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        var message: String?
        LibraryProvider(client: client(box, runner, env: box.environment(library: ""))).load {
            if case .failure(let e) = $0 { message = e.message }
        }
        XCTAssertEqual(message, LibraryProvider.noLibraryMessage)
        XCTAssertTrue(runner.starts.isEmpty)
    }

    func testFailedCatalogReportsTheJobMessage() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "failed", message: "游戏库所在的磁盘没有连接。")], 1, false) }
        let done = expectation(description: "load")
        var message: String?
        LibraryProvider(client: client(box, runner)).load { if case .failure(let e) = $0 { message = e.message }; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(message, "游戏库所在的磁盘没有连接。")
    }
}

final class SettingsProviderTests: XCTestCase {
    func testOtherSettingsKeepTheRememberedExportFolder() throws {
        let box = try Sandbox(); defer { box.remove() }
        let c = client(box, FakeRunner())
        let file = box.privateRoot.appendingPathComponent("apple-frontend/launch-settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"exportLocation":"/original/new-storage"}"#.utf8).write(to: file)
        let settings = SettingsProvider(client: c)
        XCTAssertEqual(settings.exportLocation, "/original/new-storage")
        try settings.setExportLocation("/original/selected-storage")
        try settings.setExportTargets(["mac"])
        try settings.setAIControl(true)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["exportLocation"] as? String, "/original/selected-storage", "修改其他设置不能丢掉上次选择的位置")
        XCTAssertEqual(SettingsProvider(client: c).exportLocation, "/original/selected-storage")
        // 按游戏记（11-15「玩家自行选择优先」）：给 A 选的只管 A，B 没选过取不到；重开仍在；全局「上次手动选」照记
        try settings.setExportLocation("/vol/a-folder", game: "0100A")
        XCTAssertEqual(SettingsProvider(client: c).exportLocation(forGame: "0100A"), "/vol/a-folder")
        XCTAssertNil(SettingsProvider(client: c).exportLocation(forGame: "0100B"))
        XCTAssertEqual(SettingsProvider(client: c).exportLocation, "/vol/a-folder")
    }

    /// 这一层设置表一行都没有（逐款选项在启动设置，走作业层 community）；本地文件只记出包平台勾选，旧文件里的 games（语言 / 底座）读时丢、写时不再带。
    func testNoGameOptionsAndOldLocalChoicesAreDropped() throws {
        let box = try Sandbox(); defer { box.remove() }
        let c = client(box, FakeRunner())
        let file = box.privateRoot.appendingPathComponent("apple-frontend/launch-settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"games":{"0100A":{"gameLanguage":"ja","docked":"0"}},"exportTargets":["macos"]}"#.utf8).write(to: file)
        XCTAssertEqual(S2ArmEngineProvider(client: c).settingsSchema(for: GameInfo(summary: GameSummary(id: "0100A", name: "A"))).rows, [])
        let settings = SettingsProvider(client: c)
        XCTAssertEqual(settings.exportTargets, ["macos"])
        try settings.setExportTargets(["ios", "macos"])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(saved["games"])
        XCTAssertEqual(saved["exportTargets"] as? [String], ["ios", "macos"])
    }

    /// 审计 P2-273：写盘失败时内存改回原值（原先内存已是新值、磁盘还是旧的，之后按没存下的值走、下次启动又回到旧的）。
    ///   设置文件的上级放成普通文件，建目录必失败
    func testFailedWriteKeepsThePreviousValueInMemory() throws {
        let box = try Sandbox(); defer { box.remove() }
        let blocker = box.privateRoot.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let settings = SettingsProvider(client: client(box, FakeRunner()), store: blocker.appendingPathComponent("launch-settings.json"))
        XCTAssertThrowsError(try settings.setCloudSavesFolder("/tmp/cloud"))
        XCTAssertNil(settings.cloudSavesFolder)
        XCTAssertThrowsError(try settings.setAIControl(true))
        XCTAssertFalse(settings.aiControl)
        let targetsBefore = settings.exportTargets
        XCTAssertThrowsError(try settings.setExportTargets(["ios"]))
        XCTAssertEqual(settings.exportTargets, targetsBefore)
        XCTAssertThrowsError(try settings.setExportLocation("/original/storage"))
        XCTAssertNil(settings.exportLocation)
    }
}

final class PlayServiceTests: XCTestCase {
    func testPlaySubmitsLaunchWithFrozenChoicesStopCancelsAndOnlyOneRuns() throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("stage", message: "验证运行文件"), eventLine("stage", message: "游戏运行中")], 0, true) }
        let play = PlayService(client: client(box, runner))
        var stages: [String] = []
        let done = expectation(description: "finish")
        var outcome: JobOutcome?
        try play.play(gameId: "0100A", uiLanguage: "en",
                      onEvent: { if $0.type == "stage" { stages.append($0.message) } },
                      onFinish: { outcome = $0; done.fulfill() })
        XCTAssertTrue(play.isRunning)
        XCTAssertThrowsError(try play.play(gameId: "0100B")) { XCTAssertEqual(($0 as? JobClientError)?.message, "已有一局在运行，请先停止。") }
        let req = try XCTUnwrap(runner.starts.first?.request)
        XCTAssertEqual(runner.starts.count, 1)
        XCTAssertEqual(req["operation"] as? String, "launch")
        XCTAssertEqual(req["gameId"] as? String, "0100A")
        XCTAssertNil(req["gameLanguage"])   // 游戏语言 / 主机模式不走请求字段：启动设置存 launch.json、作业层 launch_env 转
        XCTAssertNil(req["docked"])
        XCTAssertEqual(req["uiLanguage"] as? String, "en")
        XCTAssertNil(req["S2A_SAVE_DIR"])
        testQueue.sync {}   // 先把已吐的阶段事件收完再停
        play.stop()
        wait(for: [done], timeout: 5)
        testQueue.sync {}
        XCTAssertEqual(stages, ["验证运行文件", "游戏运行中"])
        XCTAssertEqual(outcome?.state, .cancelled)
        XCTAssertFalse(play.isRunning)
    }

    func testUILanguageIsPassedThroughForTheJobLayerToResolve() throws {
        // 法文界面原先不带 uiLanguage，作业层回落中文，自签导出文件夹成了「S2Arm 自签导出」（#502）：现在照原样带，作业层自己认
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        let c = client(box, runner)
        let play = PlayService(client: c)
        let done = expectation(description: "finish")
        try play.play(gameId: "0100A", uiLanguage: "fr", onFinish: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runner.starts.first?.request["uiLanguage"] as? String, "fr")
    }
}
