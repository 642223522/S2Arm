// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import XCTest
@testable import S2ArmApple

final class LauncherWindowSizeTests: XCTestCase {
    func testLaptopUsesSeventyPercentOfFullScreenHeight() {
        let size = AppSetup.defaultWindowSize(displaySize: CGSize(width: 1440, height: 900),
                                             visibleSize: CGSize(width: 1440, height: 838))
        XCTAssertEqual(size.width, 1120, accuracy: 0.001)
        XCTAssertEqual(size.height, 630, accuracy: 0.001)
    }

    func testExternalDisplayUsesItsOwnDimensions() {
        let size = AppSetup.defaultWindowSize(displaySize: CGSize(width: 2560, height: 1440),
                                             visibleSize: CGSize(width: 2560, height: 1380))
        XCTAssertEqual(size.width, 1792, accuracy: 0.001)
        XCTAssertEqual(size.height, 1008, accuracy: 0.001)
    }

    func testPortraitDisplayFitsWidthWithoutDistortingAspectRatio() {
        let size = AppSetup.defaultWindowSize(displaySize: CGSize(width: 1080, height: 1920),
                                             visibleSize: CGSize(width: 1080, height: 1840))
        XCTAssertEqual(size.width, 1080, accuracy: 0.001)
        XCTAssertEqual(size.height, 607.5, accuracy: 0.001)
    }
}
