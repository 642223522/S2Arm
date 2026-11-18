// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

/// 「S 级优化升级」页（v0.4.0）四态离屏出图（S2A_SGRADE_SHOT=<目录> 时存图看样子）：
///   有可升级且有 iPhone 件 → 两个升级按钮；全没找到原始程序 → 只给确认；找到但全无补丁 → 只给确认；查找中。
///   判据：分组按 sgradeScan 的字段分对（文案用键名代替，直接看渲染出的可访问文本不可靠，故核分组函数的输入输出与图非空）
@MainActor final class SGradeUpgradeTests: XCTestCase {
    static func g(_ id: String, _ name: String, program: String = "saved", patches: [String: Int] = [:], iphone: Bool = true, off: Bool = false) -> SGradeScanGame {
        SGradeScanGame(["id": id, "name": name, "program": program, "total": patches.values.reduce(0, +), "patches": patches, "iphone": iphone, "off": off])
    }
    static let texts = ["title": "S 级优化升级", "scanning": "正在查找游戏库里各款游戏的原始程序…", "found": "找到了 {0} 款游戏的原始程序。",
                        "yes": "可以升级到 S 级优化", "no.none": "补丁库里没有", "no.version": "补丁是别的版本的", "version.mine": "（你这份是 {0}）", "cat.cheatPlain": "金手指", "off": "出包时选了不打入，不升级", "missing": "没找到原始程序，需要重新出包覆盖更新",
                        "none": "以下游戏均不支持 S 级优化。", "nothing": "很遗憾，本游戏库中没有找到可供升级的源文件，需要麻烦您重新出包覆盖更新。",
                        "macNote": "macOS 玩家无需额外操作，下次启动游戏自动生效。", "here": "在电脑上升级",
                        "iphoneNote": "只换程序，手机上的游戏资源和存档都不动；自签导出请用原来的包名签名。", "ok": "确认", "close": "关闭",
                        "cat.widescreen": "满屏", "cat.fps": "帧率", "cat.cheat": "金手指 {0} 条", "cat.gfx": "画面"]

    func render(_ games: [SGradeScanGame]?, _ name: String, lang: String? = nil, buttonTitles: [String: String] = [:]) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Branding/s-gold.png").standardized
        let img = try XCTUnwrap(NSImage(contentsOf: src))
        let view = SGradeUpgradeBody(games: games, failure: nil, zh: true, x: { k in buttonTitles[k] ?? lang.map { BackendText.launcherText("sgrade.upgrade." + k, language: $0) } ?? Self.texts[k] ?? k }, upgrade: { _ in }, close: {}, sImage: img)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation)))
        if let dir = ProcessInfo.processInfo.environment["S2A_SGRADE_SHOT"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("upgrade_\(name).png")) }
        return rep
    }

    /// 单款升级的阶段进度（作业 sgradeUpgradeGame：stageIndex / stageCount，_bf 段 sgrade.bf 没有段内百分比）：
    ///   期望手算：3 段的第 1 段开始 0、第 3 段开始 2/3；2 段第 2 段 1/2；_bf 段 → 不定进度；没有阶段字段 → 不改
    func testStageProgress() {
        typealias M = S2ArmLauncherModel
        XCTAssertEqual(M.sgradeStageProgress(["stageKey": "sgrade.mac", "stageIndex": 1, "stageCount": 3]), .some(.some(0)))
        XCTAssertEqual(M.sgradeStageProgress(["stageKey": "sgrade.ios", "stageIndex": 3, "stageCount": 3]), .some(.some(2.0 / 3.0)))
        XCTAssertEqual(M.sgradeStageProgress(["stageKey": "sgrade.ios", "stageIndex": 2, "stageCount": 2]), .some(.some(0.5)))
        XCTAssertEqual(M.sgradeStageProgress(["stageKey": "sgrade.bf", "stageIndex": 2, "stageCount": 3]), .some(.none))
        XCTAssertNil(M.sgradeStageProgress(["message": "x"]))
    }

    func testScanFieldsParse() {
        let a = SGradeScanGame(["id": "0100A", "name": "甲", "program": "none", "total": 0, "patches": ["fps": 2], "iphone": true])
        XCTAssertFalse(a.found); XCTAssertEqual(a.patches["fps"], 2); XCTAssertFalse(a.off)
        XCTAssertTrue(SGradeScanGame(["id": "0100B", "program": "mac"]).found)
        XCTAssertTrue(SGradeScanGame(["id": "0100C", "program": "mac", "total": 1, "ownWiden": true]).ownWiden, "S2Arm 通用满屏（作业层 total 已算 +1）")
        XCTAssertEqual(SGradeScanGame(["id": "0100B"]).name, "0100B", "没名字用程序号")
    }

    // 没有对应补丁拆两组（定稿表，作业层 sgradeScan versions）：有别的版本的 → 每类写哪个版本（离玩家最近且更新的；全旧取最新的旧版本）+ 你这份是 X；都没有 → 补丁库里没有
    func testNoPatchSplitsIntoNoneAndOtherVersion() throws {
        let other = SGradeScanGame(["id": "B", "name": "乙", "program": "saved", "total": 0, "patches": [:], "iphone": true,
                                    "versions": ["mine": "1.0.0", "available": ["widescreen": ["1.2.0"], "fps": ["1.2.0", "1.3.0"]]]])
        let older = SGradeScanGame(["id": "F", "name": "己", "program": "saved", "total": 0, "patches": [:], "iphone": true,
                                    "versions": ["mine": "1.3.0", "available": ["cheat": ["1.1.0"]]]])
        XCTAssertEqual(other.mine, "1.0.0"); XCTAssertEqual(other.available["fps"], ["1.2.0", "1.3.0"])
        XCTAssertTrue(Self.g("E", "戊").available.isEmpty, "没带 versions = 补丁库里没有")
        let body = SGradeUpgradeBody(games: nil, failure: nil, zh: true, x: { Self.texts[$0] ?? $0 }, upgrade: { _ in }, close: {})
        XCTAssertEqual(body.versionsText(other), "满屏 1.2.0、帧率 1.2.0（你这份是 1.0.0）")
        XCTAssertEqual(body.versionsText(older), "金手指 1.1.0（你这份是 1.3.0）")
        let split = try render([Self.g("A", "甲", patches: ["widescreen": 1]), other, older, Self.g("E", "戊")], "split")
        XCTAssertGreaterThan(split.pixelsHigh, 0)
    }

    func testFourStatesRender() throws {
        let mixed = [Self.g("A", "甲", patches: ["widescreen": 1, "fps": 2, "cheat": 12]), Self.g("B", "乙"), Self.g("C", "丙", patches: ["fps": 1], off: true),
                     Self.g("D", "丁", program: "none")]
        let big = try render(mixed, "mixed"), nothing = try render([Self.g("D", "丁", program: "none")], "nothing")
        let none = try render([Self.g("B", "乙"), Self.g("E", "戊", program: "mac", iphone: false)], "none"), scanning = try render(nil, "scanning")
        XCTAssertGreaterThan(big.pixelsHigh, nothing.pixelsHigh, "可升级页列了四组 + 按钮，比「没找到」页高")
        XCTAssertGreaterThan(none.pixelsHigh, scanning.pixelsHigh)
    }

    // 同一正文、同一页宽，只改变按钮标题；不能用不同语言的总高度推断按钮是否换行，正文与页宽也会影响高度。
    func testLongButtonsStackInsteadOfTruncating() throws {
        let games = [Self.g("A", "甲", patches: ["fps": 1])]
        let short = try render(games, "buttons_short", lang: "en", buttonTitles: ["here": "Upgrade", "close": "Close"])
        let long = try render(games, "buttons_long", lang: "en", buttonTitles: [
            "here": "Upgrade every listed game on this computer in the background, one at a time",
            "close": "Close the S-grade upgrade page and go back to the library"
        ])
        XCTAssertEqual(long.pixelsWide, short.pixelsWide)
        XCTAssertGreaterThan(long.pixelsHigh, short.pixelsHigh + 40, "长按钮排不下时应竖排，不能截断到与短标题同高")
    }
}
