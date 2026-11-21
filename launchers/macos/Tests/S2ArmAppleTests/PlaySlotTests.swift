// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 一局单独一个游戏槽（作业层执行锁读写化：起局拿执行锁共享 + 这款的按款锁，出包拿执行锁共享 + 出包锁 + 这款的按款锁）：
//   出包另一款时能开始玩、玩着时能给另一款出包；同一款不边玩边出包；全库独占动作（删除 / 清缓存 / 导入…）在跑时不开局；
//   手机作业对正在玩的那款排队；一局的事件只进游戏槽，终局收尾不动主槽的出包会话。期望值按上面的规则手写
@MainActor final class PlaySlotTests: XCTestCase {
    private var root: URL!
    private var runner: PlaySlotRunner!
    private var model: S2ArmLauncherModel!
    private let a = GameSummary(id: "0100A", name: "Alpha", ready: true)
    private let b = GameSummary(id: "0100B", name: "Beta", ready: true)

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-playslot-" + UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data().write(to: jobs.appendingPathComponent("main.py"))
        runner = PlaySlotRunner()
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
    }

    // 先关执行器再删目录（11-20 全套里偶发 XCTUnwrap 读不到请求文件、记在别的用例头上）：async tearDown 不在主线程，
    //   主线程上一单收尾后自动接起的作业（排队的装机、刷新）会和删目录同时进行——请求刚写进去就被删、假执行器读空。
    //   close 与读请求同一把锁：删目录一定排在进行中的读取之后；之后才到的作业按「空结果」结束，不属于任何用例
    override func tearDown() async throws { runner.close(); try? FileManager.default.removeItem(at: root) }

    func testExportingOtherGameAllowsPlay() {
        model.session = JobSession(kind: .export, gameID: a.id, name: a.name)
        XCTAssertTrue(model.canPlay(b.id), "主槽在出 A：B 照样能玩")
        XCTAssertFalse(model.canPlay(a.id), "主槽在出 A：A 不能玩")
        model.session = JobSession(kind: .prepare, gameID: a.id, name: a.name)
        XCTAssertTrue(model.canPlay(b.id), "准备运行（出 Mac 版）同出包")
        XCTAssertFalse(model.canPlay(a.id))
        model.session?.phase = .finished(.completed)
        XCTAssertTrue(model.canPlay(a.id), "出完了：A 能玩")
    }

    func testLibraryWideJobsBlockPlay() {
        let kinds: [JobSession.Kind] = [.delete, .clearCache, .importGames, .keys, .moveGame, .setupLibrary, .downloadMetal, .installDotnet, .diagnostics, .exportTV]
        for kind in kinds {
            model.session = JobSession(kind: kind, gameID: kind == .importGames ? nil : a.id, name: "x")
            XCTAssertFalse(model.canPlay(a.id), "\(kind) 在跑：A 不能玩")
            XCTAssertFalse(model.canPlay(b.id), "\(kind) 在跑：B 也不能玩（全库独占）")
        }
    }

    func testOnePlayAtATimeAndCloudSync() {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertFalse(model.canPlay(b.id), "游戏槽一次一局")
        XCTAssertFalse(model.canPlay(a.id))
        XCTAssertTrue(model.busy); XCTAssertFalse(model.mainBusy); XCTAssertTrue(model.playBusy)
        model.playSession = nil
        model.cloudSyncing = true
        XCTAssertFalse(model.canPlay(a.id), "在同步 iCloud 存档：不开局")
    }

    func testPlayingAllowsExportOfOtherGameOnly() {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertNil(model.exportBlocker(b, platforms: [.mac]), "玩 A 时出 B：不挡")
        XCTAssertEqual(model.exportBlocker(a, platforms: [.mac]), .busy, "玩 A 时出 A：挡")
        XCTAssertEqual(model.export(a, platforms: [.mac]), .busy)
        XCTAssertNil(model.session, "出 A 没起作业")
        XCTAssertNil(model.export(b, platforms: [.mac]))
        XCTAssertEqual(model.session?.kind, .export); XCTAssertEqual(model.session?.gameID, b.id, "出 B 进主槽")
        XCTAssertEqual(model.playSession?.gameID, a.id); XCTAssertEqual(model.playSession?.phase, .running, "一局不受影响")
    }

    func testBatchPendingGameCannotBePlayed() {
        model.batchState = ["batch": ["items": [
            ["gameId": a.id, "platforms": ["mac"], "results": ["mac": ["state": "pending"]]],
            ["gameId": b.id, "platforms": ["mac"], "results": ["mac": ["state": "completed"]]]]]]
        model.batchRunning = true
        XCTAssertFalse(model.canPlay(a.id), "这批里 A 还没出：不能玩")
        XCTAssertTrue(model.canPlay(b.id), "这批里 B 出好了：能玩")
        model.batchRunning = false
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertTrue(model.batchHoldsPlay(), "在玩 A、A 在这批里没出完：继续 / 重试先不开始")
        XCTAssertFalse(model.batchHoldsPlay([b.id]), "只重试 B：不挡")
    }

    func testPhoneJobForPlayingGameQueuesUntilPlayEnds() async {
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        XCTAssertTrue(model.mainHolds(a.id), "正在玩的那款算被占着")
        XCTAssertFalse(model.mainHolds(b.id))
        model.install(a, device: "00008160-FIXTURE")
        XCTAssertEqual(model.phoneQueue.map(\.gameID), [a.id], "装正在玩的那款：排队")
        XCTAssertNil(model.phoneSession)
        model.finish(.completed, message: "", slot: .game)
        XCTAssertEqual(model.phoneQueue.count, 0, "一局结束：排着的装机接上")
        XCTAssertEqual(model.phoneSession?.kind, .install); XCTAssertEqual(model.phoneSession?.gameID, a.id)
    }

    func testPlayEventsGoToGameSlotAndLeaveExportAlone() async throws {
        model.session = JobSession(kind: .export, gameID: b.id, name: b.name)   // 主槽在出 B
        model.play(a, uiLanguage: nil)
        for _ in 0..<300 where model.playSession?.stage != "游戏运行中" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.playSession?.kind, .play); XCTAssertEqual(model.playSession?.gameID, a.id)
        XCTAssertEqual(model.playSession?.stage, "游戏运行中", "一局的阶段进游戏槽")
        XCTAssertEqual(model.session?.stage, "", "主槽的出包会话没收到一局的事件")
        XCTAssertEqual(model.session?.log, [])
        XCTAssertTrue(model.playSessionActive)

        runner.endLaunch()
        for _ in 0..<300 where model.playBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.playSession?.phase, .finished(.completed), "终局按游戏槽收尾")
        XCTAssertEqual(model.session?.kind, .export); XCTAssertEqual(model.session?.gameID, b.id)
        XCTAssertEqual(model.session?.phase, .running, "主槽的出包会话照旧在跑")
        XCTAssertTrue(model.canPlay(a.id), "一局结束：A 能再开（主槽出的是 B）")
    }

    func testStopPlayOnlyStopsGameSlot() {
        model.session = JobSession(kind: .export, gameID: b.id, name: b.name)
        model.playSession = JobSession(kind: .play, gameID: a.id, name: a.name)
        model.stopPlay()
        XCTAssertEqual(model.playSession?.phase, .stopping)
        XCTAssertEqual(model.session?.phase, .running, "停一局不停出包")
        model.stop()
        XCTAssertEqual(model.session?.phase, .stopping)
    }
}

/// 假作业执行器：launch 先发一条「游戏运行中」阶段事件、扣住结局（endLaunch 放出）；别的作业当场回空结果
private final class PlaySlotRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    private let lock = NSLock()
    private var held: (() -> Void)?
    private var closed = false

    /// 用例收尾：之后再起的作业不读请求文件（目录要删了），当场按空结果结束
    func close() { lock.withLock { closed = true } }

    func endLaunch() { let f = lock.withLock { () -> (() -> Void)? in let f = held; held = nil; return f }; f?() }

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let path = try XCTUnwrap(arguments.last)
        let read = try lock.withLock { () -> [String: Any]? in
            if closed { return nil }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        }
        guard let request = read else { DispatchQueue.main.async { onExit(0) }; return Handle() }
        let task = request["taskId"] ?? ""
        func line(_ e: [String: Any]) { onLine(try! JSONSerialization.data(withJSONObject: e)) }
        if request["operation"] as? String == "launch" {
            DispatchQueue.main.async {
                line(["schema": 1, "taskId": task, "type": "stage", "state": "running", "stage": "游戏运行中", "message": "游戏运行中"])
            }
            lock.withLock {
                held = { DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "result", "state": "completed", "result": [:], "message": ""]); onExit(0) } }
            }
        } else {
            DispatchQueue.main.async { line(["schema": 1, "taskId": task, "type": "result", "state": "completed", "result": ["crashed": []], "message": ""]); onExit(0) }
        }
        return Handle()
    }
}
