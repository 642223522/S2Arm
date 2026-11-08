import XCTest
@testable import S2ArmLauncher

final class PresetTests: XCTestCase {
    func testAllPresetsHaveNoConflicts() {
        for p in InputConfig.Preset.allCases {
            let c = InputConfig.preset(p)
            XCTAssertEqual(c.conflicts, [], "预设 \(p.title) 存在键位冲突：\(c.conflicts)")
        }
    }
    func testPresetsStayWithinSaveInputContract() {
        let validTargets = Set(InputConfig.targets)
        for p in InputConfig.Preset.allCases {
            let c = InputConfig.preset(p)
            XCTAssertEqual(c.schema, 1)
            for (t, b) in c.keyboard {
                XCTAssertTrue(validTargets.contains(t), "\(p.title) 非法目标 \(t)")
                XCTAssertTrue((0...127).contains(b.code), "\(p.title) 键码越界 \(t)=\(b.code)")
                XCTAssertTrue((0...7).contains(b.modifiers))
            }
            for (t, m) in c.mouse {
                XCTAssertTrue(validTargets.contains(t))
                XCTAssertTrue((0...4).contains(m), "\(p.title) 鼠标码越界 \(m)")
            }
            XCTAssertTrue(c.deadzone >= 0 && c.deadzone < 1)
            XCTAssertTrue((0.1...10).contains(c.mouseOptions.sensitivityX))
            XCTAssertTrue((0.1...10).contains(c.mouseOptions.sensitivityY))
            XCTAssertTrue(["camera","off"].contains(c.mouseOptions.mode))
        }
    }
    func testPresetsActuallyDifferFromStandard() {
        for p in InputConfig.Preset.allCases {
            XCTAssertNotEqual(InputConfig.preset(p), InputConfig.standard, "预设 \(p.title) 与标准映射完全相同，等于没做")
        }
        // 三套之间也要互不相同
        let all = InputConfig.Preset.allCases.map { InputConfig.preset($0) }
        XCTAssertEqual(Set(all.map { "\($0.keyboard)\($0.mouse)\($0.mouseOptions)" }).count, 3, "三套预设之间有重复")
    }
    func testPresetsSurviveJSONRoundTrip() throws {
        for p in InputConfig.Preset.allCases {
            let c = InputConfig.preset(p)
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(InputConfig.self, from: data)
            XCTAssertEqual(c, back, "预设 \(p.title) JSON 往返后不一致")
        }
    }
}
