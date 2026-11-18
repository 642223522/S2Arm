// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 0.6.0 iPhone 总控台（通用壳开关后面）。期望按《0.6.0 极简流程》界面一节手写：
//   首位卡状态行自上而下取第一条成立的（介绍卡 → 正在更新 → 没连 → 没装 → 有新版 → 已到期 / 快到期 → N 款建议更新 → 已装好还剩约 N 天）；
//   建议更新的默认勾上，玩家取消的不重勾；「更新所选」按游戏库顺序一款款推到总控台这台，「停下」停在当前这款、排着的不推
@MainActor final class PhoneConsoleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func phone(online: String?? = nil, installed: Bool = true, current: Bool = true, expires: TimeInterval? = 6 * 86_400 - 60,
                       games: [PhoneOverview.Game] = [], device: String = "D1", lastSeen: Date? = nil) -> PhoneOverview.Phone {
        PhoneOverview.Phone(device: device, name: "我的手机", installed: installed, shellCurrent: current, bundleId: "io.s2arm.games.T", signedAt: nil, free: true,
                            expiresAtEstimate: expires.map { now.addingTimeInterval($0) }, online: online, lastSeen: lastSeen, signMode: .appleId, games: games)
    }
    private func game(_ id: String, _ s: PhoneOverview.GameState) -> PhoneOverview.Game { .init(gameId: id, state: s, reasons: s == .suggested ? ["shader"] : [], dataOnComputer: true) }

    private func makeModel(_ runner: JobProcessRunner = ConsoleRunner()) throws -> S2ArmLauncherModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-console-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
    }

    func testParseResult() {
        XCTAssertNil(PhoneOverview(result: ["enabled": false, "phones": []]), "开关关着 → 不出首位卡")
        let o = PhoneOverview(result: ["enabled": true, "phones": [
            ["device": "D1", "name": "我的手机", "installed": true, "shellCurrent": false, "free": true, "expiresAtEstimate": 2_000_000_000, "lastSeen": 1_999_990_000,
             "online": NSNull(), "signMode": "devCert",
             "games": [["gameId": "0100a", "state": "suggested", "reasons": ["hostAbi"]], ["gameId": "0100B", "state": "needsData", "dataOnComputer": false],
                       ["gameId": "0100C", "state": "weird"]]],
            ["device": "D2", "name": "旧手机"]]])
        XCTAssertEqual(o?.phones.count, 2)
        let p = try? XCTUnwrap(o?.phones.first)
        XCTAssertEqual(p?.signMode, .devCert); XCTAssertEqual(p?.shellCurrent, false)
        XCTAssertEqual(p?.online.map { $0 == nil }, true, "带了 online 键、值为空 = 问过、没连")
        XCTAssertNil(o?.phones.last?.online ?? nil, "没带 online 键 = 没问")
        XCTAssertEqual(p?.games.map(\.gameId), ["0100A", "0100B"], "游戏号转大写；不认识的状态丢掉")
        XCTAssertEqual(p?.games.last?.dataOnComputer, false)
    }

    func testStatusOrder() throws {
        let m = try makeModel()
        XCTAssertEqual(m.consoleStatus(now: now), .introduce, "从没装过也没连过：介绍卡")
        m.phoneOverview = PhoneOverview(phones: [phone(online: .some(nil), installed: false, lastSeen: now)])
        XCTAssertEqual(m.consoleStatus(now: now), .notConnected(lastSeen: now), "没连排在没装前面")
        m.phoneOverview = PhoneOverview(phones: [phone(installed: false)])
        XCTAssertEqual(m.consoleStatus(now: now), .notInstalled)
        m.phoneOverview = PhoneOverview(phones: [phone(current: false, expires: -10)])
        XCTAssertEqual(m.consoleStatus(now: now), .appOutdated, "有新版排在到期前面")
        m.phoneOverview = PhoneOverview(phones: [phone(expires: -10)])
        XCTAssertEqual(m.consoleStatus(now: now), .expired)
        m.phoneOverview = PhoneOverview(phones: [phone(expires: 86_400 + 5, games: [game("0100A", .suggested)])])
        XCTAssertEqual(m.consoleStatus(now: now), .expiring(days: 2), "1 天多一点按 2 天；快到期排在建议更新前面")
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .suggested), game("0100C", .latest)])])
        XCTAssertEqual(m.consoleStatus(now: now), .suggested(count: 2))
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100C", .latest)])])
        XCTAssertEqual(m.consoleStatus(now: now), .ok(days: 6))
        m.phoneOverview = PhoneOverview(phones: [phone(expires: nil)])
        XCTAssertEqual(m.consoleStatus(now: now), .ok(days: nil), "没有到期估值（证书用户）不写天数")
    }

    func testWhichPhone() throws {
        let m = try makeModel()
        m.phoneOverview = PhoneOverview(phones: [phone(device: "OLD", lastSeen: now.addingTimeInterval(-99)), phone(device: "NEW", lastSeen: now)])
        XCTAssertEqual(m.consolePhone?.device, "NEW", "没选过：最近同步过的那台")
        m.phoneOverview = PhoneOverview(phones: [phone(online: .some("usb"), device: "OLD", lastSeen: now.addingTimeInterval(-99)), phone(device: "NEW", lastSeen: now)])
        XCTAssertEqual(m.consolePhone?.device, "OLD", "连着的那台优先")
        m.consoleDevice = "NEW"
        XCTAssertEqual(m.consolePhone?.device, "NEW", "顶部切过就管那台")
    }

    func testSuggestedTickedOnceAndUntickRespected() throws {
        let m = try makeModel()
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .latest)])])
        m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, ["0100A"], "建议更新的默认勾上，其余不勾")
        m.consoleSelection.remove("0100A"); m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, [], "玩家取消的不重勾")
        m.phoneOverview = PhoneOverview(phones: [phone(games: [game("0100A", .suggested), game("0100B", .suggested)])])
        m.seedConsoleSelection()
        XCTAssertEqual(m.consoleSelection, ["0100B"], "新出现的建议更新款补勾")
    }

    func testUpdateSelectedPushesInOrderToThisPhoneAndStop() async throws {
        let runner = ConsoleRunner(holdFirst: true)
        let m = try makeModel(runner)
        m.refresh()   // 假 catalog 给 A、B、C 三款；假 phoneOverview 给一台 D9
        for _ in 0..<300 where m.games.count < 3 || m.phoneOverview == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.consolePhone?.device, "D9")
        m.consoleSelection = ["0100C", "0100A", "0100B"]
        m.updateSelected()
        XCTAssertEqual(m.consoleBatch, ["0100A", "0100B", "0100C"], "按游戏库顺序")
        for _ in 0..<300 where runner.installs.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.first?["gameId"] as? String, "0100A"); XCTAssertEqual(runner.installs.first?["device"] as? String, "D9", "推总控台这台")
        XCTAssertEqual(m.consoleStatus(now: now), .updating(done: 0, total: 3))
        m.stopUpdateSelected()
        XCTAssertEqual(m.consoleBatch, ["0100A"], "停在当前这款")
        runner.release()
        for _ in 0..<300 where !m.consoleBatch.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 1, "排着的不再推")
        XCTAssertTrue(m.consoleBatch.isEmpty, "这一轮收尾")
    }
}

/// 假作业进程：install 记下请求；holdFirst 时第一单挂着直到 release()，其余作业照常成功
private final class ConsoleRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var installs: [[String: Any]] = []
    let holdFirst: Bool
    private var held: (() -> Void)?
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func release() { held?(); held = nil }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        let result: [String: Any] = switch request["operation"] as? String ?? "" {
        case "catalog": ["games": ["0100A", "0100B", "0100C"].map { ["id": $0, "name": $0, "ready": true, "missing": [String]()] }]
        case "phoneOverview": ["enabled": true, "phones": [["device": "D9", "name": "测试手机", "installed": true, "shellCurrent": true, "games": [[String: Any]]()]]]
        default: [:]
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        let finish = { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        if request["operation"] as? String == "install" {
            installs.append(request)
            if holdFirst && installs.count == 1 { held = { DispatchQueue.main.async(execute: finish) }; return Handle() }
        }
        DispatchQueue.main.async(execute: finish)
        return Handle()
    }
}
