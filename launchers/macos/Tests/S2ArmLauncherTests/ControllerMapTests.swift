import XCTest
import SwiftUI
@testable import S2ArmLauncher

@MainActor final class ControllerMapTests: XCTestCase {
    func testNintendoFacePositionsAndCoverageMatchInputABI() {
        XCTAssertEqual(ControllerMapLayout.face[0][1], "X")
        XCTAssertEqual(ControllerMapLayout.face[1][0], "Y")
        XCTAssertEqual(ControllerMapLayout.face[1][2], "A")
        XCTAssertEqual(ControllerMapLayout.face[2][1], "B")
        XCTAssertEqual(Set(ControllerMapLayout.targets), Set(InputConfig.targets))
        XCTAssertEqual(ControllerMapLayout.targets.count, InputConfig.targets.count)
    }
    func testJoyConOutlineKeepsOfficialAspectRatioAndFrontViewAnchors() {
        XCTAssertEqual(JoyConGeometry.height / JoyConGeometry.width, 102 / 35.9, accuracy: 0.0001)
        let bounds = JoyConShell().path(in: CGRect(x: 0, y: 0, width: JoyConGeometry.width, height: JoyConGeometry.height)).boundingRect
        XCTAssertEqual(bounds.width, JoyConGeometry.width, accuracy: 0.001)
        XCTAssertEqual(bounds.height, JoyConGeometry.height, accuracy: 0.001)
        XCTAssertLessThan(JoyConGeometry.upperY, JoyConGeometry.lowerY)
        XCTAssertLessThan(JoyConGeometry.lowerY, JoyConGeometry.auxiliaryY)
        XCTAssertLessThan(JoyConGeometry.stickDiameter, JoyConGeometry.width/2)
    }
    func testBindingSummaryAndConflictsTrackActualConfiguration() {
        var config = InputConfig.standard
        XCTAssertEqual(config.shortBinding("A"), "E")
        XCTAssertEqual(config.shortBinding("Y"), mouseButtonName(0))
        XCTAssertTrue(config.conflictingTargets.isEmpty)
        config.keyboard["B"] = config.keyboard["A"]
        XCTAssertEqual(config.conflictingTargets, Set(["A", "B"]))
        config.keyboard["B"] = KeyBinding(code: 53)
        config.mouse["A"] = 0
        XCTAssertEqual(config.conflictingTargets, Set(["A", "Y"]))
    }
    func testSingleButtonRevertDoesNotOverwriteOtherEditsOrOptions() {
        let original = InputConfig.standard
        var config = original
        config.keyboard["A"] = KeyBinding(code: 36)
        config.keyboard["B"] = KeyBinding(code: 53)
        config.mouse["A"] = 2
        config.gamepad["A"] = nil
        config.mouseOptions.mode = "off"
        config.restoreTarget("A", from: original)
        XCTAssertEqual(config.keyboard["A"], original.keyboard["A"])
        XCTAssertEqual(config.mouse["A"], original.mouse["A"])
        XCTAssertEqual(config.gamepad["A"], original.gamepad["A"])
        XCTAssertEqual(config.keyboard["B"]?.code, 53)
        XCTAssertEqual(config.mouseOptions.mode, "off")
    }
    func testEnglishControlsCopyDoesNotFallBackToChinese() {
        let old = Localization.preference; defer { Localization.preference = old }
        Localization.preference = .english
        for text in ["键盘", "Switch 按键位置", "点击一个按键", "游戏中的提示", "具体功能以游戏提示为准", "摇杆外侧箭头表示推杆方向。HOME / 截图键仅作示意。", "点选手柄上的按键，在右侧查看本次启动使用的输入。具体功能以游戏提示为准。"] {
            XCTAssertNil(L(text).range(of: #"[\p{Han}]"#, options: .regularExpression), text)
        }
    }
    func testEditorAndReadOnlyMapRenderInBothLanguages() throws {
        let oldLanguage = Localization.preference; defer { Localization.preference = oldLanguage }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root); store.engineSupportsInput = true
        for language in [AppLanguage.english, .simplifiedChinese] {
            Localization.preference = language
            for scheme in [ColorScheme.light, .dark] {
              for tab in ["bindings", "list", "options", "test"] {
                let view = NSHostingView(rootView: InputEditor(game: nil, initial: .standard, initialTab: tab).environmentObject(store).environment(\.colorScheme, scheme))
                view.frame = NSRect(x: 0, y: 0, width: 1040, height: 790)
                view.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                XCTAssertGreaterThan(image.pixelsWide, 0)
              }
            }
        }
    }
}
