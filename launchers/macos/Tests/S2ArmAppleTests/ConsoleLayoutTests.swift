// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 首页选中首位「S2Arm」卡时的总控台面板，在最小窗口宽度到常见宽度、中英文下都不能比窗口宽（玩家录屏 0.6.2：
//   面板与「游戏同步」各行被窗口右边缘切掉、像一大块空灰框）；卡片里的手机图标不能被搬到卡片外。
//   只离屏出图：NSHostingView 定尺寸直接排版，不进窗口、不在桌面弹窗。S2A_SNAPSHOT_OUT 给了就把每张图写出来人工看
@MainActor final class ConsoleLayoutTests: XCTestCase {
    private func makeModel(games: Int) async throws -> S2ArmLauncherModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-console-layout-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root,
            library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: LayoutCatalogRunner(count: games)))
        model.refresh()
        for _ in 0..<200 where model.games.count != games { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.count, games)
        return model
    }

    /// 没装 S2Arm、连着的一台手机；每款都「还没推 · 电脑上资源删了」（最长的那句状态）
    private func phone(_ ids: [String]) -> PhoneOverview {
        PhoneOverview(phones: [.init(device: "D1", name: "我的 iPhone", installed: false, shellCurrent: false, bundleId: "", signedAt: nil, free: true,
                                     expiresAtEstimate: nil, online: .some("D1"), lastSeen: nil, signMode: .appleId,
                                     games: ids.map { .init(gameId: $0, state: .notPushed, reasons: [], dataOnComputer: false) })])
    }

    private func render(_ model: S2ArmLauncherModel, size: CGSize, name: String) async throws -> NSHostingView<some View> {
        let host = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "S2Arm × NX2Apple"))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)   // App 整窗深色（LauncherView preferredColorScheme）；离屏不进窗口，外观要自己给
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250))
        model.selectedID = S2ArmLauncherModel.consoleID   // 首页 onAppear 会把选中归到第一款：排完第一遍再选首位卡
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250)) }
        XCTAssertTrue(model.consoleSelected)
        if let out = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
        }
        return host
    }

    func testConsolePanelFitsWindowWidth() async throws {
        for lang in ["zh-Hans", "en"] {
            // 设置里的语言选择只放进本进程参数域（不写盘），同 TestLanguage 固定系统语言的做法
            let d = UserDefaults.standard
            var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
            args["appLanguage"] = lang
            d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            let model = try await makeModel(games: 6)
            model.phoneOverview = phone(model.games.map(\.id))
            for width in [800.0, 900, 1000, 1200, 1280, 1440] {
                let size = CGSize(width: width, height: 760)
                let host = try await render(model, size: size, name: "console-\(lang)-\(Int(width))")
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5, "\(lang) \(Int(width)) 宽：首页内容的最小宽度不能比窗口宽（否则右边被切）")
            }
            args["appLanguage"] = nil
            d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        }
    }
}

private final class LayoutCatalogRunner: JobProcessRunner {
    let count: Int
    init(count: Int) { self.count = count }
    final class Handle: JobProcessHandle { func terminate() {} }
    func start(executable: URL, arguments: [String], environment: [String: String], onLine: @escaping (Data) -> Void,
               onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        var result: [String: Any] = [:]
        if request["operation"] as? String == "phoneOverview" {   // 选中首位卡会现查一次：回同一台没装 S2Arm 的手机，每款都「还没推 · 电脑上资源删了」
            let games = (0..<count).map { ["gameId": String(format: "%016X", $0), "state": "notPushed", "reasons": [], "dataOnComputer": false] as [String: Any] }
            result = ["phones": [["device": "D1", "name": "我的 iPhone", "installed": false, "shellCurrent": false, "bundleId": "", "free": true,
                                  "online": "D1", "signMode": "appleId", "games": games] as [String: Any]]]
        }
        if request["operation"] as? String == "catalog" {
            let names = ["The Legend of Fixture: Breath of the Long Test Name", "Fixture Kart 8 Deluxe", "霍格沃茨之遗（测试夹具）",
                         "电视台的山乡神曲风情（测试夹具）", "Original Fixture 4", "Original Fixture 5"]
            let games = (0..<count).map { i -> [String: Any] in
                ["id": String(format: "%016X", i), "name": names[i % names.count], "ready": true, "missing": [], "customCover": false,
                 "packages": [], "iphoneInstall": NSNull()]
            }
            result = ["games": games, "keys": [:]]
        }
        let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] ?? "", "type": "result", "state": "succeeded", "result": result]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
