import AppKit
import SwiftUI
import XCTest
@testable import S2ArmLauncher

// 社区资源一节（10-27 维护者 01:4x 口径）：后端 JSON 解得出；宽屏 / 60 帧勾选框 + 固定耗电提示、跨版本定位说明、画面互斥单选都能渲染。
//   设 S2A_SNAPSHOT_OUT=<目录> 时存 community_zh.png 供肉眼核对（数据是单测夹具，不是真游戏的补丁）
@MainActor final class CommunityViewTests: XCTestCase {
    func testDecodeAndRender() throws {
        let result: [String:Any] = ["gameId":"0100C2500FC20000", "version":"4.1.0",
            "widescreen":["verified":true, "sources":["Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods"], "relocate":false, "available":true, "enabled":true],
            "fps60":["verified":false, "sources":["ADEMOLA200/Switch-Emulator-Mod-Database"], "relocate":true, "available":true, "enabled":false],
            "graphics":[
                ["id":"gfx:res1080","label":"1080p","exclusive":"res","source":"社区 A","state":"community","relocate":false,"enabled":true],
                ["id":"gfx:res900","label":"900p","exclusive":"res","source":"社区 A","state":"community","relocate":false,"enabled":false],
                ["id":"gfx:noblur","label":"关动态模糊","exclusive":"","source":"S2Arm","state":"verified","relocate":true,"enabled":true]]]
        let state = try XCTUnwrap(Store.communityState(result), "后端 JSON 解得出")
        XCTAssertEqual([state.widescreen.enabled, state.fps60.enabled, state.fps60.relocate], [true, false, true])
        XCTAssertEqual(state.graphics.filter { $0.exclusive == "res" && $0.enabled }.count, 1, "互斥组只开一个")
        XCTAssertNil(Store.communityState(["gameId":"x"]), "缺字段 = 解不出（界面显示加载中，不崩）")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let store = Store(privateRoot:temp)
        let game = Game(id:"0100C2500FC20000", name:"Splatoon 3", display:"4.1.0", packages:[], hidden:false)
        let view = NSHostingView(rootView:CommunitySection(game:game, state:state).environmentObject(store).padding(20).frame(width:360).background(Color(white:0.95)))
        view.frame = NSRect(x:0, y:0, width:360, height:640); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds, to:bitmap)
        if let out = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] { try XCTUnwrap(bitmap.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:out).appendingPathComponent("community_zh.png")) }
    }
}
