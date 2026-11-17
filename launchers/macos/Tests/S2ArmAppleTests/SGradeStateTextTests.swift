// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// S 级每类状态 → 给玩家看的那一句（三端状态与文案对照定稿）。期望按文案表的模板手写，不跑被测函数推导。
final class SGradeStateTextTests: XCTestCase {
    private func line(_ cat: String, _ raw: [String: Any], lang: String = "zh-Hans") -> (String, String?)? {
        let catName = BackendText.launcherText("export.sgrade.cat." + cat, language: lang)
        return SGradeStateText.line(cat: cat, catName: catName, SGradeCategoryState(raw), t: { BackendText.launcherText($0, language: lang) },
                                    date: { _ in "11-15" }).map { ($0.text, $0.reenable) }
    }
    private func eq(_ got: (String, String?)?, _ text: String, _ key: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got?.0, text, file: file, line: line); XCTAssertEqual(got?.1, key, file: file, line: line)
    }

    func testOnSaysWhichOneIsInUse() {
        // 作业层 feat/sgrade-state 口径：满屏 active = adaptive / fixed / own；帧率 active = {levels, pick}（"0" = 自动，取最高档）
        eq(line("widescreen", ["state": "on", "source": "patch", "active": "adaptive"]), "在用：社区满屏补丁（按屏幕比例自动选）")
        eq(line("widescreen", ["state": "on", "source": "patch", "active": "fixed"]), "在用：社区满屏补丁（固定画幅）")
        eq(line("widescreen", ["state": "on", "source": "own", "active": "own"]), "在用：S2Arm 通用满屏（这款没有社区满屏补丁，S2Arm 验过能铺满）")
        eq(line("fps", ["state": "on", "active": ["levels": [60, 120], "pick": "0"]]), "在用：最高 120 帧")
        eq(line("fps", ["state": "on", "active": ["levels": [60, 120], "pick": "60"]]), "在用：最高 60 帧")
        eq(line("widescreen", ["state": "on", "source": "own"], lang: "en"), "In use: S2Arm full screen (no community patch for this game; checked by S2Arm)")
    }

    func testIneffectiveShowsLastRunAsIs() {
        // 作业层原句已写「没生效：…」，不再套一层「开着，但上一局没生效：」
        eq(line("widescreen", ["state": "ineffective", "lastRun": "没生效：补丁与这个版本的游戏不配套"]), "没生效：补丁与这个版本的游戏不配套")
    }

    func testAutoOffSaysWhenAndWhyAndOffersReenable() {
        eq(line("widescreen", ["state": "off_auto", "autoOff": ["cause": "crash", "at": 1794740000]]), "已自动关：11-15 游戏崩溃时它开着", "fullscreen")
        eq(line("fps", ["state": "off_auto", "autoOff": ["cause": "stall", "at": 1794740000]]), "已自动关：11-15 画面停住时它开着", "fps")
        eq(line("fps", ["state": "off_user"]), "已关")
    }

    func testVersionPicksNearestNewerElseSaysOnlyOlder() {
        // 维护者 11-15：写离玩家最近、且比它新的；全是旧的写「只有旧版本 X 的」，不劝降级
        eq(line("fps", ["state": "version", "versions": ["mine": "1.0.2", "available": ["1.0.0", "1.1.0", "1.0.4"]]]),
           "补丁库里是 1.0.4 版的，你这份是 1.0.2。把游戏更新到 1.0.4 后重新出包就能用。")
        eq(line("fps", ["state": "version", "versions": ["mine": "1.3.0", "available": ["1.0.0", "1.2.0"]]]), "补丁只有旧版本 1.2.0 的，你这个版本暂时没有。")
        eq(line("fps", ["state": "version", "versions": ["mine": "1.9", "available": ["1.10"]]]),
           "补丁库里是 1.10 版的，你这份是 1.9。把游戏更新到 1.10 后重新出包就能用。", nil)   // 按段比，1.10 比 1.9 新
        eq(line("widescreen", ["state": "version", "versions": ["mine": "1.0.2", "available": ["1.0.4"], "port": "failed"]]),
           "补丁库里是 1.0.4 版的，你这份是 1.0.2。把游戏更新到 1.0.4 后重新出包就能用。已试过移植到你这份，没成功。")
        XCTAssertNil(line("fps", ["state": "version", "versions": ["mine": "1.0", "available": []]]), "没有别的版本可说就不出")
    }

    func testNoneOptedOutMacOnlyAndSilentStates() {
        eq(line("widescreen", ["state": "none"]), "补丁库里还没有这款游戏的满屏补丁。")
        eq(line("widescreen", ["state": "none"], lang: "en"), "The patch library has no full screen patch for this game yet.")
        eq(line("fps", ["state": "opted_out"]), "没打入：出包时取消了「出包时打入」。重新出包时勾上就有。")
        eq(line("gfx", ["state": "mac_only"]), "画面补丁只在 Mac 版里。")
        XCTAssertNil(line("widescreen", ["state": "pending"]), "Mac 下次起局自动补上，不用说")
        XCTAssertNil(line("widescreen", ["state": "unknown"]))
        XCTAssertNil(line("widescreen", [:]), "作业层还没出 sgradeState：不画")
    }

    func testFiveLanguagesHaveEveryStateKey() {
        // 加语言只加叠加文件：每个 sgrade.state.* 在繁中 / 日 / 西 / 法都有译文（缺了会回落英文，这里要求齐）
        let keys = ["sgrade.state.on.adaptive", "sgrade.state.on.fixed", "sgrade.state.on.own", "sgrade.state.on.fps", "sgrade.state.off_user",
                    "sgrade.state.off_auto.crash", "sgrade.state.off_auto.stall", "sgrade.state.reenable", "sgrade.state.version.newer",
                    "sgrade.state.version.older", "sgrade.state.version.port_failed", "sgrade.state.none", "sgrade.state.opted_out",
                    "sgrade.state.pending.ios", "sgrade.state.mac_only", "sgrade.state.restored", "sgrade.upgrade.no.none", "sgrade.upgrade.no.version"]
        for lang in ["zh-Hant", "ja", "es", "fr"] {
            for k in keys {
                XCTAssertNotEqual(BackendText.launcherText(k, language: lang), BackendText.launcherText(k, language: "en"), "\(lang) 缺 \(k)")
            }
        }
    }

    private func row(_ cat: String, _ raw: [String: Any]?, hasPatch: Bool = false, fpsOn: Bool = false) -> (String, Bool)? {
        let t = { (k: String) in BackendText.launcherText(k, language: "zh-Hans") }
        return SGradeStateText.rowNote(cat: cat, raw.map(SGradeCategoryState.init), hasFpsPatch: hasPatch, fpsOn: fpsOn, t: t, date: { _ in "11-15" }).map { ($0.text, $0.disabled) }
    }

    func testTopRowNotesSayWhatIsInUse() {
        // 11-15 齿轮页一级三行：与 iPhone t_sgrade_line 同输入同一句（期望按定稿手写）
        XCTAssertEqual(row("widescreen", ["state": "on", "source": "patch", "active": "adaptive"])?.0, "社区补丁 · 按屏幕比例自动选")
        XCTAssertEqual(row("widescreen", ["state": "on", "source": "patch", "active": "fixed"])?.0, "社区补丁 · 固定画幅")
        XCTAssertEqual(row("widescreen", ["state": "off_user", "source": "own"])?.0, "S2Arm 通用满屏（这款没有社区补丁）")
        XCTAssertEqual(row("widescreen", nil)?.0, "S2Arm 通用满屏（这款没有社区补丁）")
        XCTAssertEqual(row("widescreen", ["state": "off_auto", "source": "own", "autoOff": ["cause": "crash", "at": 1794740000]])?.0, "已自动关：11-15 游戏崩溃时它开着")
        XCTAssertEqual(row("fps", ["state": "on", "source": "patch", "active": ["levels": [60, 120], "pick": "0"]], hasPatch: true, fpsOn: true)?.0, "社区补丁 · 最高 120 帧")
        XCTAssertEqual(row("fps", ["state": "off_user", "source": "fi", "active": ["levels": [120], "pick": "0"]], hasPatch: true)?.0, "补帧：30 帧补到 60 帧")
        XCTAssertEqual(row("fps", ["source": "fi"])?.0, "补帧：30 帧补到 60 帧（这款没有社区补丁）")
        let none = row("fps", ["source": "none", "fiSupported": false])
        XCTAssertEqual(none?.0, "这台设备不支持补帧"); XCTAssertEqual(none?.1, true, "没补丁且设备不支持补帧：真用不了才置灰")
        let patched = row("fps", ["source": "none", "fiSupported": false, "active": ["levels": [60], "pick": "0"]], hasPatch: true)
        XCTAssertEqual(patched?.0, "社区补丁 · 最高 60 帧"); XCTAssertEqual(patched?.1, false)
        XCTAssertEqual(row("fps", nil)?.0, "补帧：30 帧补到 60 帧（这款没有社区补丁）")
        let unsup = row("fps", ["state": "unsupported", "source": "fi"])
        XCTAssertEqual(unsup?.0, "这台设备不支持补帧"); XCTAssertEqual(unsup?.1, true)
        XCTAssertEqual(row("widescreen", ["state": "off_auto", "source": "own", "autoOff": ["cause": "widen_fit", "at": 1794740000]])?.0, "已自动关：11-15 满屏没铺满或画面被拉伸")
    }

    func testTopRowKeysInEveryLanguage() {
        for lang in ["zh-Hant", "ja", "es", "fr"] {
            for k in ["sgrade.row.fps", "sgrade.src.fs.adaptive", "sgrade.src.fs.fixed", "sgrade.src.fs.own", "sgrade.src.fps.patch", "sgrade.src.fps.fi",
                      "sgrade.src.fps.fi.nopatch", "sgrade.unavail.fi", "sgrade.cheats.none", "sgrade.cpatch.detail", "sgrade.notice.fullscreen_off"] {
                XCTAssertNotEqual(BackendText.launcherText(k, language: lang), BackendText.launcherText(k, language: "en"), "\(lang) 缺 \(k)")
            }
        }
    }
}
