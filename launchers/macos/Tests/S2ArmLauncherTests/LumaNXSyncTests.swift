import XCTest
import SwiftUI
import AppKit
@testable import S2ArmLauncher

final class LumaNXSyncTests: XCTestCase {
    @MainActor func testUtilityHeadingsAndPanelsUseCompactGeometry() {
        _ = NSApplication.shared
        for title in ["设置", "Settings", "跨平台编译", "Cross-platform builds"] {
            let heading=NSHostingView(rootView:WorkspaceHeading(title:title,subtitle:"",symbol:"gearshape") {EmptyView()})
            XCTAssertLessThanOrEqual(heading.fittingSize.height,32.5,title)
        }
        let panel=NSHostingView(rootView:GlassPanel {Color.clear.frame(width:100,height:20)})
        XCTAssertEqual(panel.fittingSize.height,44,accuracy:0.5,"20-point content with 12-point card insets")
    }

    /// LumaNX's library controls share a 42-point capsule, including the search field.
    @MainActor func testLibraryCountersKeepTheReferenceControlHeight() {
        _ = NSApplication.shared
        for title in ["款游戏", "Games", "可启动", "Ready"] {
            let view = NSHostingView(rootView:LibraryStat(title:title,value:123,symbol:"play.fill"))
            XCTAssertEqual(view.fittingSize.height,42,accuracy:0.5,title)
        }
    }

    func testWorkspaceLabelsAndCountTemplatesTranslateToEnglish() {
        let cases = [
            "导入版本": "Imported version",
            "诊断详情": "Diagnostic details",
            "进行中 2": "In progress 2",
            "等待中 3": "Queued 3",
            "环境详情与工具": "Environment details and tools",
            "管理游戏": "Manage game",
            "清理与移除": "Cleanup and removal",
            "游戏详情": "Game details",
            "已折叠": "Collapsed",
            "有更新待准备": "Updates awaiting preparation",
            "准备条件未满足": "Requirements not met"
        ]
        for (source, english) in cases {
            XCTAssertEqual(Localization.translate(source, language:"en"), english, source)
        }
    }
}
