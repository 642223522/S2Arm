import XCTest
import SwiftUI
@testable import S2ArmLauncher

@MainActor final class InputGuideTests: XCTestCase {
    func testPreferenceChangesNotifyTheVisibleGuideInBothDirections() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.setInputGuideShown(false, for: "0100000000000001")
        XCTAssertFalse(store.inputGuideShown(for: "0100000000000001"))
        XCTAssertGreaterThan(changes, 0)
        let before = changes
        store.setInputGuideShown(true, for: "0100000000000001")
        XCTAssertTrue(store.inputGuideShown(for: "0100000000000001"))
        XCTAssertGreaterThan(changes, before)
        withExtendedLifetime(observation) {}
    }
    func game(_ id: String, _ name: String, supported: Bool = true) -> Game {
        Game(id: id, name: name, display: "1", packages: [], hidden: false, inputConfig: supported)
    }
    func testPreferencesArePerGamePersistentAndReadableByNativeContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        XCTAssertTrue(store.inputGuideShown(for: "0100000000000001"))
        store.setInputGuideShown(false, for: "0100000000000001")
        XCTAssertFalse(Store(privateRoot: root).inputGuideShown(for: "0100000000000001"))
        XCTAssertTrue(store.inputGuideShown(for: "0100000000000002"))
        let path = root.appendingPathComponent("input-guides/0100000000000001.json")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(value["gameId"] as? String, "0100000000000001")
        XCTAssertEqual(value["show"] as? Bool, false)
        store.setInputGuideShown(true, for: "0100000000000001")
        XCTAssertTrue(Store(privateRoot: root).inputGuideShown(for: "0100000000000001"))
        XCTAssertTrue(store.processes.isEmpty)
    }
    func testGameSpecificMappingAndSnapshotRemainBoundToTheSelectedGame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        store.preferences.library = root.appendingPathComponent("library").path
        let mappings = store.libraryURL.appendingPathComponent("mappings")
        try FileManager.default.createDirectory(at: mappings, withIntermediateDirectories: true)
        var custom = InputConfig.standard; custom.keyboard["A"] = KeyBinding(code: 36)
        try JSONEncoder().encode(custom).write(to: mappings.appendingPathComponent("0100000000000001.json"))
        let first = game("0100000000000001", "First game")
        let second = game("0100000000000002", "Second game")
        store.prepareInputGuide(first)
        let guide = try XCTUnwrap(store.inputGuide)
        XCTAssertEqual(guide.game.name, "First game")
        XCTAssertEqual(guide.config.keyboard["A"]?.code, 36)
        store.globalInput.keyboard["A"] = KeyBinding(code: 3)
        store.prepareInputGuide(second)
        XCTAssertEqual(store.inputGuide?.game.name, "Second game")
        XCTAssertEqual(store.inputGuide?.config.keyboard["A"]?.code, 3)
        XCTAssertEqual(guide.config.keyboard["A"]?.code, 36)
        let arguments = guide.launchArguments
        XCTAssertEqual(arguments["gameId"] as? String, first.id)
        let config = try XCTUnwrap(Store.decode(InputConfig.self, arguments["launchInputConfig"]))
        XCTAssertEqual(config, custom)
        store.confirmInputGuide(guide) // An old sheet must not start the wrong game.
        XCTAssertEqual(store.inputGuide?.game.id, second.id)
        XCTAssertTrue(store.processes.isEmpty)
    }
    func testUnsupportedEngineDoesNotPassSavedMappingAsConfirmedInput() {
        let presentation = InputGuidePresentation(game: game("0100000000000001", "Legacy", supported: false), config: .standard, supported: false)
        XCTAssertNil(presentation.launchArguments["launchInputConfig"])
        XCTAssertEqual(presentation.launchArguments["inputGuideHandled"] as? Bool, true)
    }
    func testHandledControlLaunchDoesNotLeaveAHumanConfirmationCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let title = game("0100000000000001", "Automation fixture")
        store.prepareInputGuide(title)
        XCTAssertNotNil(store.inputGuide)
        // Readiness is intentionally false: route past the guide but do not spawn a host.
        store.prepareInputGuide(title, handled: true)
        XCTAssertNil(store.inputGuide)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.processes.isEmpty)
        XCTAssertTrue(store.inputGuideShown(for: title.id)) // Automation doesn't change human preference.
    }
    func testOptionalSavedFieldsMatchNativeDefaultsAndCorruptionDoesNotBorrowGlobalInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root); store.preferences.library = root.appendingPathComponent("library").path
        let mappingRoot = store.libraryURL.appendingPathComponent("mappings")
        try FileManager.default.createDirectory(at: mappingRoot, withIntermediateDirectories: true)
        let fixture = """
        {"schema":1,"keyboard":{"A":{"code":36}},"mouse":{},"gamepad":{},"axes":{"LX":{"source":"leftX"}},"deadzone":0.15,"mouseOptions":{"mode":"off","sensitivityX":1,"sensitivityY":1}}
        """
        let path = mappingRoot.appendingPathComponent("0100000000000001.json")
        try Data(fixture.utf8).write(to: path)
        store.prepareInputGuide(game("0100000000000001", "Optional fields"))
        XCTAssertEqual(store.inputGuide?.config.keyboard["A"], KeyBinding(code: 36))
        XCTAssertEqual(store.inputGuide?.config.axes["LX"]?.invert, false)
        XCTAssertEqual(store.inputGuide?.config.mouseOptions.invertX, false)
        store.inputGuide = nil
        try Data("{broken".utf8).write(to: path)
        store.prepareInputGuide(game("0100000000000001", "Corrupt fields"))
        XCTAssertNil(store.inputGuide)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.processes.isEmpty)
    }
    func testGuideRendersForTwoGamesAndBothInterfaceLanguages() throws {
        let previous = Localization.preference; defer { Localization.preference = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        for language in [AppLanguage.english, .simplifiedChinese] {
            Localization.preference = language
            if language == .english { XCTAssertEqual(L("键盘"), "Keyboard") }
            for supported in [true, false] {
                let presentation = InputGuidePresentation(game: game("0100000000000001", "Fixture \(supported)", supported: supported), config: .standard, supported: supported)
                let view = NSHostingView(rootView: InputGuideView(presentation: presentation).environmentObject(store))
                view.frame = NSRect(x: 0, y: 0, width: 1040, height: 790)
                view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(view.fittingSize.height, 0)
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                XCTAssertGreaterThan(image.pixelsWide, 0)
            }
        }
    }
}
