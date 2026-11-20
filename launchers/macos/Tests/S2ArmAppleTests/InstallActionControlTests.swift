import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 替身作业：catalog 给一款；installCheck 给一份清单（出好了包、没登录 Apple ID、没连手机），每项带作业层 MAC_READY_ACTIONS 的动作
private final class ChecklistRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        var taskId = "", op = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""; op = request["operation"] as? String ?? ""
        }
        let item = { (id: String, ok: Bool, action: Any) -> [String: Any] in ["id": id, "ok": ok, "waiting": false, "title": id, "detail": "", "who": "human", "action": action] }
        let result: [String: Any]
        switch op {
        case "catalog": result = ["games": [["id": "0100ABCDEF000000", "name": "Fixture", "ready": true, "missing": []]]]
        case "installCheck": result = ["gameId": "0100ABCDEF000000", "ready": true, "items": [item("package", true, NSNull()), item("appleId", false, "appleLogin"),
                                                                                               item("connected", false, "pickDevice"), item("deviceReady", false, NSNull())]]
        case "appleAccount": result = ["account": "player@example.com", "team": "T", "teamName": "Tester", "enabled": true]
        default: result = [:]
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}

/// 控制口 /install-action：按当前清单里那一项的 action 走界面同一个派发；GET /state 的 presented 说当前打开了什么。期望手写
@MainActor final class InstallActionControlTests: XCTestCase {
    func testAppleIdItemOpensLoginPanel() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-install-action-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for d in ["Jobs", "lib", "logs/jobs"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: ChecklistRunner()))
        let control = try S2ArmControl(model: model) { XCTFail($0) }
        defer { control.stop() }
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let gid = try XCTUnwrap(model.games.first?.id)
        func post(_ body: [String: Any]) async -> (Int, [String: Any]) {
            let r = await control.handle(ControlRequest(method: "POST", path: "/install-action", headers: [:], body: body))
            return (r.code, (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:])
        }
        let early = await post(["gameId": gid, "id": "appleId"])
        XCTAssertEqual(early.0, 409, "还没有这款的清单")
        XCTAssertTrue(control.state()["presented"] is NSNull, "什么都没开：null")

        model.checkInstall(gid)
        for _ in 0..<300 where model.installReadiness == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let items = (control.state()["installReadiness"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.first { $0["id"] as? String == "appleId" }?["action"] as? String, "appleLogin", "状态里的清单项带 action")

        let done = await post(["gameId": gid, "id": "package"])
        XCTAssertEqual(done.0, 409, "已好的一项没有动作")
        let waiting = await post(["gameId": gid, "id": "deviceReady"])
        XCTAssertEqual(waiting.0, 409, "不用人做的一项没有动作")
        let missing = await post(["gameId": gid])
        XCTAssertEqual(missing.0, 400)

        let (code, body) = await post(["gameId": gid, "id": "appleId"])
        XCTAssertEqual(code, 200); XCTAssertEqual(body["action"] as? String, "appleLogin")
        XCTAssertEqual(control.state()["presented"] as? String, "appleLogin", "没登录时点 appleId：登录面板开着")
        XCTAssertEqual(model.appleLoginHost, "install", "从装机窗弹")
        XCTAssertEqual(model.showInstallFor, gid, "装机窗没开就先开这款的")
        model.closeAppleLogin()
        XCTAssertTrue(control.state()["presented"] is NSNull)

        let pick = await post(["gameId": gid, "id": "connected"])
        XCTAssertEqual(pick.0, 200)
        XCTAssertEqual(control.state()["presented"] as? String, "pickDevice")
        _ = await post(["gameId": gid, "id": "appleId"])
        let dismissed = await control.handle(ControlRequest(method: "POST", path: "/dismiss", headers: [:], body: [:]))
        XCTAssertEqual(dismissed.code, 200)
        XCTAssertTrue(control.state()["presented"] is NSNull, "/dismiss 收起清单动作打开的东西（同 Windows）")
        XCTAssertNil(model.appleLoginHost)

        // 装机报登录过期（apple_session_expired）：失败页按钮落到同一个登录面板，带「过期」并重读账号带上原来的邮箱；没登录不带原因
        XCTAssertEqual(S2ArmLauncherModel.appleLoginCodes["apple_session_expired"], .some("expired"))
        XCTAssertEqual(S2ArmLauncherModel.appleLoginCodes["apple_not_signed_in"], .some(nil))
        XCTAssertNil(S2ArmLauncherModel.appleLoginCodes["cert_revoke_confirm"], "别的码不落登录面板")
        model.openAppleLogin(host: "main", reason: "expired")
        for _ in 0..<300 where model.appleAccount == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(control.state()["presented"] as? String, "appleLogin")
        XCTAssertEqual(model.appleLoginReason, "expired")
        XCTAssertEqual(model.appleAccount?.account, "player@example.com", "面板邮箱框按它带上原来的邮箱")
        model.closeAppleLogin()
        XCTAssertNil(model.appleLoginReason)
    }
}
