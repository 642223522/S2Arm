// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 0.6.0 空间页四类（作业层 pack/jobs/sizes.py categories，通用壳开关开着才带）：带了就按「资源、程序、玩家数据、缓存、原件」列；
//   缺的类记 0；不带照旧五项（Mac 版、iPhone 版、存档、缓存、原件）。期望手写
final class GameSizesRowsTests: XCTestCase {
    func testFourCategoriesWhenPresent() {
        let s = GameSizes(catalog: ["imageMac": 1, "imageIos": 2, "saves": 3, "cache": 4, "sources": 5, "measured": true,
                                    "categories": ["resources": 7_000_000_000, "programs": 20, "playerData": 30] as [String: Any]])
        let rows = GameSizesList.rows(s)
        XCTAssertEqual(rows.map(\.id), ["resources", "programs", "playerData", "cache", "sources"])
        XCTAssertEqual(rows.map(\.bytes), [7_000_000_000, 20, 30, 0, 5], "缺的类记 0，超过 Int32 的照样对")
    }

    func testOldFivePartsWithoutCategories() {
        let s = GameSizes(catalog: ["imageMac": 1, "imageIos": 2, "saves": 3, "cache": 4, "sources": 5, "measured": true])
        XCTAssertNil(s.categories)
        XCTAssertEqual(GameSizesList.rows(s).map(\.id), ["imageMac", "imageIos", "saves", "cache", "sources"])
    }
}
