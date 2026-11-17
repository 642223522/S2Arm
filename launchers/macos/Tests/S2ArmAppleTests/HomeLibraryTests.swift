// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
import LauncherPadBridge
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

@MainActor final class HomeLibraryTests: XCTestCase {
    // 新主题漏掉的补回来：每张卡片上的 iPhone 签名角标（还剩几天 / 已过期）
    func testHomeCardsShowExpiryBadges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeArtwork(to: root)
        let now = Date().timeIntervalSince1970, day = 86400.0
        // 第 0 款：6.5 天前装 → 还剩 1 天；第 1 款：8 天前 → 已过期；第 2 款：1 天前 → 还剩 6 天
        let runner = HomeCatalogRunner(artwork: root, installs: [0: now - 6.5 * day, 1: now - 8 * day, 2: now - day])
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root,
            library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.refresh()
        for _ in 0..<100 where model.games.count != 21 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.first { $0.id == String(format: "%016X", 0) }?.iphoneDaysLeft(), 1)
        XCTAssertEqual(model.games.first { $0.id == String(format: "%016X", 1) }?.iphoneDaysLeft(), 0)
        let host = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "S2Arm × NX2Apple"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        model.selectedID = String(format: "%016X", 3)
        // 角标是卡片按钮里的装饰（无障碍信息合进卡片按钮），这里只核天数口径；样子看 S2A_SNAPSHOT_OUT 出的 home-cards.png
        XCTAssertEqual(model.games.first { $0.id == String(format: "%016X", 2) }?.iphoneDaysLeft(), 6)
        XCTAssertNil(model.games.first { $0.id == String(format: "%016X", 3) }?.iphoneDaysLeft(), "没装过的款没有角标")
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        if let output = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("home-cards.png"))
        }
        window.close()
    }

    func testHomeExposesHorizontalCoversAboveActions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeArtwork(to: root)
        let runner = HomeCatalogRunner(artwork: root)
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root,
            library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.refresh()
        for _ in 0..<100 where model.games.count != 21 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.count, 21)
        let host = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "S2Arm × NX2Apple"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let targets = model.gamepad.controlTargets(in: window)
        XCTAssertTrue(targets.contains { $0.id == "library.sgradeUpgrade" }, "合并主线后首页仍须提供可用手柄操作的 S 级优化升级入口")
        let cards = targets.filter { $0.id.hasPrefix("card.") }
        XCTAssertGreaterThanOrEqual(cards.count, 5, "Home 首屏必须能浏览一排游戏")
        let firstCard = try XCTUnwrap(cards.min { $0.frame.minX < $1.frame.minX })
        let play = try XCTUnwrap(targets.first { $0.id == "hero.play" })
        XCTAssertLessThan(play.frame.maxY, cards.map(\.frame.minY).min()!, "游戏操作必须放在顶部封面排下方")
        XCTAssertLessThan(cards.map(\.frame.maxY).max()! - cards.map(\.frame.maxY).min()!, 2, "全部封面必须在同一横排顶对齐")
        let secondCard = try XCTUnwrap(cards.first { $0.id == "card." + String(format: "%016X", 1) })
        XCTAssertGreaterThan(firstCard.frame.width, secondCard.frame.width * 1.2, "选中封面必须明显放大")
        for id in ["top.library", "top.settings", "top.report", "top.controller", "top.messages", "top.player"] {
            let target = try XCTUnwrap(targets.first { $0.id == id }, id)
            XCTAssertLessThanOrEqual(target.frame.width, 44, "顶栏操作尽量图标化：\(id)")
            XCTAssertGreaterThanOrEqual(target.frame.height, 32)
        }
        let firstID = String(format: "%016X", 0)
        let firstPixel = try pixel(host, x: 0.88, y: 0.5)
        XCTAssertGreaterThan(firstPixel.redComponent, firstPixel.blueComponent + 0.15, "第一款红色 banner 必须铺到窗口右半侧（没自定义过封面时用横幅）")
        model.gamepad.focus("card." + firstID)
        model.gamepad.handle(.left)
        XCTAssertEqual(model.selectedID, firstID, "第一款向左不能越界或跳进其他操作")
        model.gamepad.handle(.right)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.selectedID, String(format: "%016X", 1), "右键选择下一款游戏")
        let secondPixel = try pixel(host, x: 0.88, y: 0.5)
        XCTAssertGreaterThan(secondPixel.blueComponent, secondPixel.redComponent + 0.15, "选择第二款后全屏背景必须换成蓝色 banner")
        model.gamepad.handle(.down)
        XCTAssertEqual(model.gamepad.focusedID, "hero.play", "封面向下进入游戏操作")
        model.gamepad.handle(.up)
        XCTAssertEqual(model.gamepad.focusedID, "card." + String(format: "%016X", 1), "操作区向上回到选中游戏")
        model.gamepad.handle(.up)
        XCTAssertEqual(model.gamepad.focusedID, "home.search", "封面向上进入搜索")
        model.gamepad.handle(.down)
        XCTAssertEqual(model.gamepad.focusedID, "card." + String(format: "%016X", 1))
        for _ in 0..<19 { model.gamepad.handle(.right); try await Task.sleep(for: .milliseconds(80)) }
        let lastCard = "card." + String(format: "%016X", 20)
        for _ in 0..<100 where !model.gamepad.isFullyVisible(lastCard) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.selectedID, String(format: "%016X", 20), "能横向滚动到最后一款游戏")
        XCTAssertTrue(model.gamepad.controlTargets(in: window).contains { $0.id == "card." + String(format: "%016X", 20) }, "屏外目标要实际滚入视口")
        model.gamepad.handle(.right)
        XCTAssertEqual(model.selectedID, String(format: "%016X", 20), "最后一款向右不能越界")
        model.gamepad.handle(.left)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(model.selectedID, String(format: "%016X", 19))
        if let output = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("home-console.png"))
        }
        for size in [CGSize(width: 1120, height: 630), CGSize(width: 1000, height: 720), CGSize(width: 1920, height: 1080)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let resized = model.gamepad.controlTargets(in: window)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 0.1, "内容最小高度不能撑大默认窗口")
            let screenBounds = window.convertToScreen(host.bounds)
            for id in ["hero.play", "hero.selfSign", "hero.more", "hero.favorite", "home.search"] {
                let target = try XCTUnwrap(resized.first { $0.id == id }, "\(size): \(id)")
                XCTAssertTrue(screenBounds.insetBy(dx: -1, dy: -1).contains(target.frame), "\(size) 的操作必须留在窗口内：\(id) \(target.frame)")
            }
            // Toolbar buttons live in a separate AppKit hosting view, outside the page host's bounds.
            let settings = try XCTUnwrap(resized.first { $0.id == "top.settings" })
            XCTAssertTrue(window.frame.contains(settings.frame), "原生标题栏按钮必须位于窗口内")
        }
        model.home.search = String(format: "%016X", 19)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(model.gamepad.controlTargets(in: window).filter { $0.id.hasPrefix("card.") }.count, 1, "搜索到单款时保留横排选择")
        model.home.search = "no-such-original-fixture"
        try await Task.sleep(for: .milliseconds(180))
        let empty = model.gamepad.controlTargets(in: window)
        XCTAssertTrue(empty.contains { $0.id == "home.showAll" }, "无匹配项时必须能恢复全部游戏")
        XCTAssertFalse(empty.contains { $0.id.hasPrefix("hero.") }, "没有匹配项时不能操作上一次选中的游戏")
        model.home.search = ""
        try await Task.sleep(for: .milliseconds(180))
        model.gamepad.focus("card." + String(format: "%016X", 19))
        model.gamepad.handle(.confirm)
        XCTAssertNil(runner.lastLaunch, "A 只选中当前游戏，不能同时启动")
        model.gamepad.handle(.submit)
        for _ in 0..<50 where runner.lastLaunch == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.lastLaunch, String(format: "%016X", 19), "R2 必须启动当前选中的游戏")
        try await Task.sleep(for: .milliseconds(80))
        model.session = JobSession(kind: .play, gameID: firstID, name: "Fixture")
        model.gamepad.handle(.back)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.sessionHidden, "B 返回 Home 时运行中的任务留在后台")
        XCTAssertTrue(model.gamepad.controlTargets(in: window).contains { $0.id == "top.currentTask" }, "后台任务必须有重新进入的入口：\(model.gamepad.controlTargets(in: window).map(\.id))")
        model.gamepad.focus("top.currentTask"); model.gamepad.handle(.confirm)
        XCTAssertFalse(model.sessionHidden)
        model.goToLibrary()
        XCTAssertTrue(model.sessionHidden)
        model.session = JobSession(kind: .play, gameID: firstID, name: "Next fixture")
        XCTAssertFalse(model.sessionHidden, "开始新任务时不能继承上一个任务的隐藏状态")
        window.close()
    }

    func testBackdropUsesCoverWhenBannerIsMissingOrInvalid() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-backdrop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeArtwork(to: root)
        try Data("invalid image".utf8).write(to: root.appendingPathComponent("broken.png"))
        let covers = CoverCache()
        for banner in [nil, root.appendingPathComponent("broken.png").path] as [String?] {
            var game = GameSummary(id: "fixture", name: "Original", cover: root.appendingPathComponent("cover.png").path)
            game.banner = banner
            let host = NSHostingView(rootView: HomeBackdrop(game: game, covers: covers))
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let color = try pixel(host, x: 0.88, y: 0.5)
            XCTAssertGreaterThan(color.greenComponent, color.redComponent + 0.15, "banner 缺失或无法解码时仍显示有效封面")
            window.close()
        }
        // 玩家自己换过封面：大图用玩家的封面（绿），不用自带横幅（红）——11-15 维护者「玩家自行选择优先级更高」
        var custom = GameSummary(id: "fixture", name: "Original", cover: root.appendingPathComponent("cover.png").path, customCover: true)
        custom.banner = root.appendingPathComponent("banner-red.png").path
        let host = NSHostingView(rootView: HomeBackdrop(game: custom, covers: covers))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let color = try pixel(host, x: 0.88, y: 0.5)
        XCTAssertGreaterThan(color.greenComponent, color.redComponent + 0.15, "自定义封面优先于自带横幅")
        window.close()
    }

    private func pixel(_ host: NSView, x: CGFloat, y: CGFloat) throws -> NSColor {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(bitmap.pixelsWide) * x), y: Int(CGFloat(bitmap.pixelsHigh) * y))?.usingColorSpace(.deviceRGB))
    }

    /// Original synthetic artwork only; no game resources or screenshots enter the repository.
    private static func writeArtwork(to root: URL) throws {
        for (name, color, size) in [
            ("banner-red", NSColor(red: 0.9, green: 0.14, blue: 0.08, alpha: 1), NSSize(width: 1280, height: 720)),
            ("banner-blue", NSColor(red: 0.08, green: 0.24, blue: 0.9, alpha: 1), NSSize(width: 1280, height: 720)),
            ("cover", NSColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1), NSSize(width: 256, height: 256))
        ] {
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
    }

}

private final class HomeCatalogRunner: JobProcessRunner {
    let artwork: URL
    /// 第几款是用免费账号装到 iPhone 的、什么时候装的（Unix 秒）；没写的款没装过
    let installs: [Int: Double]
    init(artwork: URL, installs: [Int: Double] = [:]) { self.artwork = artwork; self.installs = installs }
    private let lock = NSLock()
    private var launch: String?
    var lastLaunch: String? { lock.withLock { launch } }
    final class Handle: JobProcessHandle { func terminate() {} }
    func start(executable: URL, arguments: [String], environment: [String: String], onLine: @escaping (Data) -> Void,
               onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments.last!))) as! [String: Any]
        var result: [String: Any] = [:]
        if request["operation"] as? String == "launch" { lock.withLock { launch = request["gameId"] as? String } }
        if request["operation"] as? String == "catalog" {
            result = ["games": (0..<21).map { ["id": String(format: "%016X", $0),
                "name": $0 == 19 ? "Original Fixture 19 — A Very Long Adventure Across the Mountains and the Distant Sea" : "Original Fixture \($0)",
                "ready": true, "missing": [],
                "customCover": false, "cover": artwork.appendingPathComponent("cover.png").path,
                "banner": artwork.appendingPathComponent($0 % 2 == 0 ? "banner-red.png" : "banner-blue.png").path,
                "iphoneInstall": installs[$0].map { ["at": $0, "free": true] as Any } ?? NSNull()] as [String: Any] }, "keys": [:]]
        }
        let event: [String: Any] = ["schema": 1, "taskId": request["taskId"] ?? "", "type": "result", "state": "succeeded", "result": result]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
