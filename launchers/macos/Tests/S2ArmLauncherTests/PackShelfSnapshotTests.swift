import AppKit
import SwiftUI
import XCTest
@testable import S2ArmLauncher

// 已出好的 iPhone 包整页渲染：三款（一款两次出包、一款产物已清理）+ 失败 / 取消任务留在历史；设 S2A_SNAPSHOT_OUT=<目录> 存 shelf_zh.png / shelf_en.png 供肉眼核对
@MainActor final class PackShelfSnapshotTests: XCTestCase {
    func testTasksPageShowsShelfAndKeepsFailedInHistory() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let lib = temp.appendingPathComponent("lib"), store = Store(privateRoot:temp.appendingPathComponent("priv"))
        store.preferences.library = lib.path
        store.preferences.iphoneTarget = IPhoneTarget(model:"iPhone 16 Pro", productType:"iPhone17,1", gpuArch:"apple9", os:26)
        let ids = ["0100C2500FC20000", "0100F2C0115B6000", "01006F8002326000"]
        store.games = zip(ids, ["Splatoon 3（斯普拉遁 3）", "塞尔达传说 王国之泪", "集合啦！动物森友会"]).map { Game(id:$0, name:$1, display:"1.0.0", packages:[], hidden:false) }
        func ipa(_ gid:String, _ name:String, _ mode:String, _ time:String) throws -> URL {
            let d = lib.appendingPathComponent("iPhone/\(gid)"), w = temp.appendingPathComponent("w-\(name)"), app = w.appendingPathComponent("Payload/S2Arm.app")
            try FileManager.default.createDirectory(at:app, withIntermediateDirectories:true); try FileManager.default.createDirectory(at:d, withIntermediateDirectories:true)
            try PropertyListSerialization.data(fromPropertyList:["S2AGraphicsMode":mode, "S2APackTime":time, "S2ABuildID":"5b25523-\(name)"], format:.xml, options:0).write(to:app.appendingPathComponent("Info.plist"))
            let z = Process(); z.executableURL = URL(fileURLWithPath:"/usr/bin/zip"); z.currentDirectoryURL = w; z.arguments = ["-qr", d.appendingPathComponent(name).path, "Payload"]; try z.run(); z.waitUntilExit()
            let pack = d.appendingPathComponent("\(gid)资源包"); try FileManager.default.createDirectory(at:pack, withIntermediateDirectories:true)
            try "romfs/a\t5400000000\tx\n".write(to:pack.appendingPathComponent("index.tsv"), atomically:true, encoding:.utf8)
            return d.appendingPathComponent(name)
        }
        // 出包时间按「现在」往前推，与下面任务的结束时刻同一把尺（原先写死日期，11-02 09:40Z 起01006F8002326000的「25 小时前清理」就比0100F2C0115B6000新、顺序翻了）
        let now = Date().timeIntervalSince1970
        func ago(_ s:Double) -> String { ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:now - s)) }
        let newest = try ipa(ids[0], "spl3-b.ipa", "direct", ago(120)); _ = try ipa(ids[0], "spl3-a.ipa", "direct", ago(100000))
        _ = try ipa(ids[1], "totk.ipa", "direct", ago(20000))
        func task(_ id:String, _ op:String, _ state:String, _ gid:String?, _ ended:Double, _ msg:String = "操作完成") -> TaskRecord { var t = TaskRecord(id:id, operation:op, state:state, gameId:gid); t.ended = ended; t.started = ended - 1800; t.message = msg; return t }
        var done = task("ipa-4", "ipa", "completed", ids[0], now - 120); done.ipaPath = newest.path; done.outputPath = newest.deletingLastPathComponent().path
        store.tasks = [done, task("ipa-3", "ipa", "failed", ids[1], now - 3000, "直连库编译失败：着色器 37 支没编出来"), task("ipa-2", "ipa", "completed", ids[1], now - 20000),
                       task("ipa-1", "ipa", "completed", ids[2], now - 90000), task("b-1", "build", "cancelled", ids[2], now - 95000, "已让位给 iPhone 出包。")]
        store.selection = "tasks"; store.showOnboarding = false
        UserDefaults.standard.removeObject(forKey:"tasks.completionHeroDismissed")
        store.packShelf = PackShelf.scan(library:lib, games:store.games, tasks:store.tasks)
        XCTAssertEqual(store.packShelf.map(\.gameId), [ids[0], ids[1], ids[2]], "斯普拉遁 3 最新、王国之泪其次、动森产物已清理（排最后）")
        XCTAssertEqual(store.packShelf[0].versions.map(\.mode), [.direct, .direct], "真读 IPA 里的 Info.plist")
        let previous = Localization.preference; defer { Localization.preference = previous }
        for (language, tag) in [(AppLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            Localization.preference = language
            // 只渲任务页（整窗 ContentView 的分栏在离屏渲染里画成空白，TasksPageTests 同病）；放进窗口里渲，滚动视图才画内容
            let view = NSHostingView(rootView:TasksView().environmentObject(store).frame(width:1100, height:1500).background(Color(nsColor:.windowBackgroundColor)))
            let window = NSWindow(contentRect:NSRect(x:0, y:0, width:1100, height:1500), styleMask:[.borderless], backing:.buffered, defer:false)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.8)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds, to:bitmap)
            if let o = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] { try XCTUnwrap(bitmap.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:o).appendingPathComponent("shelf_\(tag).png")) }
        }
    }
}
