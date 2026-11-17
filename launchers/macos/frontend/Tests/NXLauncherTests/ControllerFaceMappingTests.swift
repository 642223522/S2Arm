// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import GameController
import SwiftUI
import XCTest
@testable import NXLauncher
@testable import NX2AppleUI

@MainActor final class ControllerFaceMappingTests: XCTestCase {
    func testAllFourPhysicalKeysMatchTheAgreedDefaultAndSwitchLayouts() throws {
        let expected: [(ControllerFaceFamily, Bool, [String], [UInt64])] = [
            (.playstation, false, ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"], [1, 2, 4, 8]),
            (.playstation, true, ["circle.circle", "xmark.circle", "triangle.circle", "square.circle"], [2, 1, 8, 4]),
            (.xbox, false, ["a.circle", "b.circle", "x.circle", "y.circle"], [1, 2, 4, 8]),
            (.xbox, true, ["b.circle", "a.circle", "y.circle", "x.circle"], [2, 1, 8, 4])
        ]
        let pad = try XCTUnwrap(GCController.withExtendedGamepad().extendedGamepad)
        let physical = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY]
        for (family, switched, symbols, bits) in expected {
            let map: ControllerFaceMapping = switched ? .switchPosition(for: family) : .identity
            let actual = map.symbols(for: family)
            XCTAssertEqual([.primary, .back, .secondary, .tertiary].map { actual[$0]! }, symbols)
            for index in 0..<4 {
                physical[index].setValue(1)
                XCTAssertEqual(LauncherPadInput.system(pad, mapping: map).buttons, bits[index])
                physical[index].setValue(0)
            }
        }
        pad.leftShoulder.setValue(1)
        XCTAssertEqual(LauncherPadInput.system(pad, mapping: .switchPosition(for: .xbox)).buttons, 1 << 6)
    }

    func testPrimaryPlayerOwnsHintsEvenWhenAnotherControllerIsActive() throws {
        let ps = FaceMappingController("DualSense Wireless Controller")
        let xbox = FaceMappingController("Xbox Wireless Controller")
        var assignment = PlayerAssignment()
        assignment.reconcile(devices: [], mergedPair: false, system: [.init(name: ps.vendorName!, index: 0), .init(name: xbox.vendorName!, index: 0)])
        let source = LauncherPadSource()
        // Enumeration deliberately disagrees with the player's assigned order.
        source.controllers = { [xbox, ps] }; source.assignment = { assignment }; source.isActive = { true }
        var hints: [PadShortcut: String] = [:], actions: [LauncherPadAction] = []
        source.updatePresentation = { _, value in hints = value }; source.receive = { actions.append($0) }
        source.faceMapping = { $0 == .playstation ? .switchPosition(for: .playstation) : .identity }
        source.tick(now: 0)
        XCTAssertEqual(hints[.primary], "circle.circle")
        let other = try XCTUnwrap(xbox.extendedGamepad)
        other.buttonA.setValue(1); source.tick(now: 0.01)
        XCTAssertEqual(hints[.back], "xmark.circle", "P2 输入不能切换主玩家提示")
        other.buttonA.setValue(0); source.tick(now: 0.02); actions.removeAll()
        let main = try XCTUnwrap(ps.extendedGamepad)
        main.buttonB.setValue(1); source.tick(now: 0.03)
        XCTAssertEqual(actions, [.confirm], "PS 实体 ○ 应按映射确认")
        main.buttonB.setValue(0); source.tick(now: 0.04)
        main.buttonA.setValue(1); source.tick(now: 0.05)
        XCTAssertEqual(actions.last, .back)
        main.buttonA.setValue(0); source.tick(now: 0.06)
        assignment = PlayerAssignment()
        assignment.reconcile(devices: [], mergedPair: false, system: [.init(name: xbox.vendorName!, index: 0), .init(name: ps.vendorName!, index: 0)])
        source.tick(now: 0.07)
        XCTAssertEqual(hints[.primary], "a.circle", "重新分配主玩家时提示改用其配置")
    }

    func testChangingMappingWhileHeldRequiresReleaseBeforeAnotherAction() throws {
        let controller = GCController.withExtendedGamepad(), source = LauncherPadSource()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        var map = ControllerFaceMapping.identity, actions: [LauncherPadAction] = []
        source.controllers = { [controller] }; source.isActive = { true }; source.faceMapping = { _ in map }
        source.receive = { actions.append($0) }; source.tick(now: 0)
        pad.buttonA.setValue(1); source.tick(now: 0.01)
        XCTAssertEqual(actions, [.confirm])
        map = .switchPosition(for: .other); source.tick(now: 0.02)
        XCTAssertEqual(actions, [.confirm], "切换映射不能把按住的确认变成一次返回")
        pad.buttonA.setValue(0); source.tick(now: 0.03)
        pad.buttonA.setValue(1); source.tick(now: 0.04)
        XCTAssertEqual(actions, [.confirm, .back])
    }

    func testDisplayedSheetActionsExecuteThroughTheMappedPhysicalButtons() async throws {
        _ = NSApplication.shared
        for name in ["DualSense Wireless Controller", "Xbox Wireless Controller"] {
            let controller = FaceMappingController(name), navigation = LauncherPadNavigation()
            let pad = try XCTUnwrap(controller.extendedGamepad)
            let physical = [pad.rightTrigger, pad.buttonB, pad.buttonX, pad.buttonY, pad.buttonA]
            var counts = [0, 0, 0, 0], mapping = ControllerFaceMapping.identity
            let shortcuts: [PadShortcut] = [.rightTrigger, .back, .secondary, .tertiary]
            let host = NSHostingView(rootView: HStack {
                ForEach(0..<4) { index in
                    Button(["Done", "Back", "Recheck", "Details"][index]) { counts[index] += 1 }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerShortcut(shortcuts[index])
                        .controllerID("actions.\(index)")
                }
            }.padding(20).environment(\.padControls, navigation))
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            navigation.source.controllers = { [controller] }; navigation.attach(window); navigation.source.stop()
            navigation.source.isActive = { true }; navigation.source.faceMapping = { _ in mapping }
            defer { navigation.detach(); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            var time: TimeInterval = 0
            for (round, sources) in [[0, 1, 2, 3], [0, 4, 3, 2]].enumerated() {
                mapping = round == 0 ? .identity : .switchPosition(for: .xbox)
                navigation.source.tick(now: time); time += 0.01
                for target in 0..<4 {
                    navigation.focus("actions.0")
                    physical[sources[target]].setValue(1); navigation.source.tick(now: time); time += 0.01
                    XCTAssertEqual(counts[target], round + 1, "\(name): 目标 \(target) 的实际动作必须与其提示一致")
                    physical[sources[target]].setValue(0); navigation.source.tick(now: time); time += 0.01
                }
            }
            XCTAssertEqual(counts, [2, 2, 2, 2])
        }
    }

    func testCustomMappingsRemainPermutationsAndPersistAcrossControllerFamilies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("faces.json"), store = ControllerFaceMapStore(fileURL: root.appendingPathComponent("faces.json"))
        var custom = ControllerFaceMapping.identity.assigning(source: 0, to: 2)
        custom = custom.assigning(source: 1, to: 3)
        XCTAssertEqual((0..<4).map { custom.source(for: $0) }, [2, 3, 0, 1])
        store.set(custom, for: .playstation)
        XCTAssertEqual(store.mapping(for: .xbox), custom)
        XCTAssertEqual(store.mapping(for: .other), custom)
        XCTAssertEqual(store.mapping(for: .nintendo), .identity)
        store.set(.switchPosition(for: .xbox), for: .xbox)
        let restored = ControllerFaceMapStore(fileURL: file)
        XCTAssertNil(restored.problem)
        XCTAssertEqual(restored.mapping(for: .playstation).code, 0xb1)
        XCTAssertEqual(restored.mapping(for: .xbox).code, 0xb1)
        restored.set(nil, for: .playstation)
        XCTAssertEqual(restored.mapping(for: .playstation), .identity)
        XCTAssertEqual(ControllerFaceMapStore(fileURL: file).mapping(for: .xbox), .identity)
        let document = try JSONDecoder().decode(ControllerFaceMapStore.Document.self, from: Data(contentsOf: file))
        XCTAssertEqual(document.schema, 2)
        XCTAssertEqual(document.mapping, ControllerFaceMapping.identity.code, "游戏宿主读取同一份统一映射")
        XCTAssertNil(document.profiles)
        XCTAssertNil(ControllerFaceMapping(code: 0))
        XCTAssertNil(ControllerFaceMapping(code: 0x1e4))
    }

    func testPopoverEditorChangesMappingsThroughItsRealDropdownAndResets() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for family in [ControllerFaceFamily.playstation, .xbox] {
            let store = ControllerFaceMapStore(fileURL: root.appendingPathComponent(family.rawValue + ".json"))
            let navigation = LauncherPadNavigation()
            let host = NSHostingView(rootView: ControllerFaceMappingEditor(store: store, family: family, simplifiedChinese: true)
                .padding(20).frame(width: 380).background(Color(white: 0.12)).preferredColorScheme(.dark)
                .launcherDropdownHost().environment(\.padControls, navigation))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            navigation.source.controllers = { [] }; navigation.attach(window); navigation.source.stop()
            defer { navigation.detach(); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            navigation.focus("controller.face.0"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(navigation.controlTargets(in: window).contains { $0.id == "dropdown.1" })
            navigation.focus("dropdown.1"); navigation.handle(.confirm)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(store.mapping(for: family).target(for: 0), 1)
            XCTAssertEqual(store.mapping(for: family).target(for: 1), 0, "改给已占用的目标时互换，保留四键可用")
            navigation.focus("controller.face.switch"); navigation.handle(.confirm)
            XCTAssertEqual(store.mapping(for: family).code, 0xb1)
            if let output = ProcessInfo.processInfo.environment["S2A_SETTINGS_SHOTS"] {
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("face-map-" + family.rawValue + ".png"))
            }
            navigation.focus("controller.face.reset"); navigation.handle(.confirm)
            XCTAssertEqual(store.mapping(for: family), .identity)
            XCTAssertEqual(store.sharedMapping, .identity)
        }
    }
}

private final class FaceMappingController: GCController {
    private let name: String
    private let gamepadSnapshot = GCController.withExtendedGamepad()
    init(_ name: String) { self.name = name; super.init() }
    override var vendorName: String? { name }
    override var productCategory: String { "Fixture Controller" }
    override var extendedGamepad: GCExtendedGamepad? { gamepadSnapshot.extendedGamepad }
}
