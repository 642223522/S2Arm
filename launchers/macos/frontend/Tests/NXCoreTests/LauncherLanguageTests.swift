import XCTest
@testable import NXCore

/// 启动器界面语言（11-13）：第一次跟随系统；设置里选过就记住、以后不再跟系统；选「跟随系统」回到跟随。
/// 规则（手写期望）：系统首选语言是中文（简中 / 繁中都算，繁中先落简中）→ 简体中文（zh），其余（英 / 日 …）→ English（en）。
final class LauncherLanguageTests: XCTestCase {
    private var kept: Any?
    override func setUp() { kept = UserDefaults.standard.object(forKey: "appLanguage"); UserDefaults.standard.removeObject(forKey: "appLanguage") }
    override func tearDown() { UserDefaults.standard.set(kept, forKey: "appLanguage") }

    func testFirstLaunchFollowsSystem() {
        XCTAssertEqual(Lang.initial(preferred: ["zh-Hans-CN"]), .zh, "简中系统")
        XCTAssertEqual(Lang.initial(preferred: ["zh-Hant-TW"]), Lang("zh-Hant"), "繁中系统落繁中（11-14 加繁中）")
        XCTAssertEqual(Lang.initial(preferred: ["zh-TW"]), Lang("zh-Hant"), "台湾地区码也落繁中")
        XCTAssertEqual(Lang.initial(preferred: ["en-US"]), .en, "英文系统")
        XCTAssertEqual(Lang.initial(preferred: ["ja-JP"]), Lang("ja"), "日文系统落日文（11-14 加日文）")
        XCTAssertEqual(Lang.initial(preferred: ["ko-KR"]), .en, "没有文案的语言落英文")
    }

    func testChoiceRemembered() {
        Lang.saved = .en   // 设置里选了 English
        XCTAssertEqual(Lang.initial(preferred: ["zh-Hans-CN"]), .en, "重启后仍是选的 English，不跟简中系统")
        Lang.saved = .zh
        XCTAssertEqual(Lang.initial(preferred: ["en-US"]), .zh, "重启后仍是选的简体中文，不跟英文系统")
    }

    func testFollowSystemAgain() {
        Lang.saved = .en
        Lang.saved = Lang.find("")   // 设置里选「跟随系统」（Localizer.choose("")）
        XCTAssertNil(Lang.saved)
        XCTAssertEqual(Lang.initial(preferred: ["zh-Hans-CN"]), .zh, "回到跟随系统")
        XCTAssertEqual(Lang.initial(preferred: ["ko-KR"]), .en)
    }
}
