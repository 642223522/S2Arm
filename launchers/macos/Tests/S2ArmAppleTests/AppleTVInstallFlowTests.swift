import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// #1429：出包页 / 出包结果页点「装到 Apple TV」，tvInstall 作业签名失败——失败要停在原处说清原因，不能回游戏库什么都没有
private final class TVRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var ops: [String] = []
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = "", op = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""; op = request["operation"] as? String ?? ""
        }
        ops.append(op)
        let failed = op == "tvInstall"
        let result: [String: Any] = op == "catalog" ? ["games": [["id": "01007EF00011E000", "name": "Fixture", "ready": true, "missing": [], "appleTvReady": true]]] : [:]
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": failed ? "failed" : "succeeded", "result": result,
                                    "message": failed ? "没有 TEAM.io.s2arm.tv.fixture 的开发描述文件" : ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(failed ? 1 : 0) }
        return Handle()
    }
}

@MainActor final class AppleTVInstallFlowTests: XCTestCase {
    func testFailedAppleTVInstallStaysOnScreenWithTheReason() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tv-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = TVRunner()
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let game = try XCTUnwrap(model.games.first)
        model.exportFor = game.id   // 在出包页上点
        model.installAppleTV(game)
        for _ in 0..<300 where model.session.map({ if case .finished = $0.phase { return false }; return true }) ?? true { try? await Task.sleep(for: .milliseconds(10)) }
        print("tv-flow ops=\(runner.ops) kind=\(String(describing: model.session?.kind)) phase=\(String(describing: model.session?.phase)) hidden=\(model.sessionHidden) result=\(model.viewingResult != nil) exportFor=\(String(describing: model.exportFor)) msg=\(model.session?.message ?? "-") actionError=\(String(describing: model.actionError(for: game.id)))")
        let s = try XCTUnwrap(model.session, "失败的 Apple TV 装机要留在作业槽里，界面才画得出来")
        XCTAssertEqual(s.kind, .installTV)
        XCTAssertEqual(s.phase, .finished(.failed))
        XCTAssertFalse(model.sessionHidden, "不能藏到后台")
        XCTAssertTrue(s.message.contains("开发描述文件"), "失败原因要带到页面上：\(s.message)")
    }
}
