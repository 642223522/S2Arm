import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 0.6.0 Mac 的 Apple ID 登录（InstallService.appleLogin / appleAccount / appleLoginCode，作业层 pack/jobs/apple_login.py）。
/// 用替身作业进程：密码只进这一次作业的环境（不进请求文件）；验证码事件认得出作业号与能否改短信；验证码文件写在 <私有目录>/login/<作业号>.code。期望手写
private let team = "FAKE" + "TEAMAB"   // 拆开写：公开仓扫描把十位字母数字当真团队号

final class AppleLoginTests: XCTestCase {
    private let password = "Pw-Unit-Adapter-41c2"   // 假密码：只许出现在子进程环境里

    func testPasswordOnlyInEnvironmentAndPromptCarriesTask() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([
            eventLine("stage", message: "等你填验证码", extra: #","stageKey":"appleLogin.needCode""#),
            eventLine("progress", extra: #","stageKey":"appleLogin.needCode","account":"player@example.com","canSms":true,"sms":false"#),
            eventLine("result", state: "succeeded", extra: #","result":{"account":"player@example.com","team":"\#(team)","teamName":"Tester","enabled":true}"#),
        ], 0, false) }
        let service = InstallService(client: client(box, runner))
        let lock = NSLock()
        var prompts: [AppleLoginPrompt] = []
        let got = try await service.appleLogin(account: "player@example.com", password: password,
                                               events: EventSink { e in if let p = AppleLoginPrompt(event: e) { lock.lock(); prompts.append(p); lock.unlock() } })
        XCTAssertEqual(got, AppleAccount(account: "player@example.com", team: team, teamName: "Tester", enabled: true))
        XCTAssertTrue(got.signedIn)
        let start = try XCTUnwrap(runner.starts.first)
        XCTAssertEqual(start.request["operation"] as? String, "appleLogin")
        XCTAssertEqual(start.request["account"] as? String, "player@example.com")
        XCTAssertEqual(start.environment[InstallService.applePasswordEnv], password, "密码经环境变量给这一次作业")
        let requestText = String(data: try JSONSerialization.data(withJSONObject: start.request), encoding: .utf8) ?? ""
        XCTAssertFalse(requestText.contains(password), "请求文件里没有密码")
        let task = try XCTUnwrap(start.request["taskId"] as? String)
        XCTAssertEqual(prompts, [AppleLoginPrompt(taskId: task, canSms: true, sms: false)], "只认带 canSms 的那条 progress，stage 事件不算")
    }

    func testCodeFileGoesWhereTheJobReadsIt() throws {
        let box = try Sandbox(); defer { box.remove() }
        let service = InstallService(client: client(box, FakeRunner()))
        let file = box.privateRoot.appendingPathComponent("login/task-1.code")   // 同作业层 apple_login._code_file：<私有目录>/login/<作业号>.code
        try service.appleLoginCode(" 123456 ", taskId: "task-1")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "123456")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        try service.appleLoginCode("SMS", taskId: "task-1")   // 改用短信接收：作业层只认小写 sms
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "sms")
        XCTAssertThrowsError(try service.appleLoginCode("12345", taskId: "task-1"))
        XCTAssertThrowsError(try service.appleLoginCode("123456", taskId: ""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["task-1.code"], "不留临时文件")
    }

    func testAccountNotSignedIn() async throws {
        let box = try Sandbox(); defer { box.remove() }
        let runner = FakeRunner()
        runner.script = { _ in ([eventLine("result", state: "succeeded", extra: #","result":{"account":null,"team":null,"teamName":"","enabled":true}"#)], 0, false) }
        let got = try await InstallService(client: client(box, runner)).appleAccount()
        XCTAssertFalse(got.signedIn)
        XCTAssertEqual(runner.starts.first?.request["operation"] as? String, "appleAccount")
        XCTAssertNil(runner.starts.first?.environment[InstallService.applePasswordEnv])
    }
}
