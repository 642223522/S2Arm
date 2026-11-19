import XCTest
@testable import S2ArmAppleAdapter

/// 启动设置页按共享定义表画：资源包里那份表要读得出来，Mac 有的项按表顺序全在。期望按 launchers/shared/game_settings.v1.json 手抄。
final class GameSettingsSpecTests: XCTestCase {
    func testMacItemsComeFromTheSharedTable() throws {
        let items = try GameSettingsSpec.macItems()
        XCTAssertEqual(items.map(\.id), ["quality", "fps60", "fpsPick", "resolutionScale", "fpsLimit", "widescreen", "docked", "language", "patches", "input", "rumble", "rumbleLevel", "motion", "motionInvertY", "motionInvertX", "padFace", "snapshot", "hud", "cheats", "mods", "pauseUnfocused", "audioLatency", "diagRun"])
        // 画质提升（11-15 取代「画面增强模式」）：三档，只有锐利放大带一句代价（选中时写在标题下）
        let quality = try XCTUnwrap(items.first { $0.id == "quality" })
        XCTAssertEqual(quality.text("zh-Hans"), "画质提升")
        XCTAssertEqual(quality.options.map(\.value), ["Bilinear", "Nearest", "MetalFX"])
        XCTAssertEqual(quality.options.map { $0.label["zh-Hans"] ?? "" }, ["标准", "2D 游戏专用", "锐利放大（MetalFX）"])
        XCTAssertEqual(quality.options.map { $0.detail("zh-Hans") }, [nil, nil, "锐利放大（MetalFX）会每帧多花一点显卡时间，帧率和能耗会略有影响。"])
        XCTAssertEqual(quality.detail("zh-Hans"), "")
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "docked" }).options.map(\.value), ["docked", "handheld"])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "rumbleLevel" }).options.count, 6)
    }

    func testBrokenTableIsAnError() {
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"other","items":[]}"#.utf8)))
        XCTAssertThrowsError(try GameSettingsSpec.macItems(Data(#"{"contract":"s2a.game-settings.v1","items":[{"platforms":["mac"]}]}"#.utf8)))
    }
}
