import AppKit
import SwiftUI
import XCTest
@testable import S2ArmLauncher

// 打包任务页（10-26 维护者 重排）：一层平铺（进行中卡片 + 已结束一行一条）、实时计数、日志末行、左栏当前任务卡片；中英文都能渲染。
//   设 S2A_SNAPSHOT_OUT=<目录> 时把整窗口存成 tasks_zh.png / tasks_en.png 供肉眼核对
@MainActor final class TasksPageTests: XCTestCase {
    func testTasksPageRendersRunningCountersAndFlatEndedList() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let store = Store(privateRoot:temp)
        let gid = "0100C2500FC20000"
        func pkg(_ type:String, _ v:Int, _ d:String, _ size:Int64) -> NSPPackage { NSPPackage(titleId:gid, baseId:gid, version:v, type:type, name:"Splatoon 3", display:d, path:"/x/\(type)\(v).nsp", size:size, sha256:"\(type)\(v)", builds:[:]) }
        store.games = [Game(id:gid, name:"Splatoon 3（斯普拉遁 3）", display:"4.1.0", packages:[pkg("base", 0, "1.0.0", 6_400_000_000), pkg("update", 4 << 16, "4.1.0", 2_100_000_000), pkg("dlc", 0, "", 3_200_000_000)], hidden:false)]
        let plan = [("unpack","解包"),("refresh","改写与准备资源"),("direct","直连着色器库"),("ipa","编 App 与签名")]   // pack/jobs/milestones.py PLANS["ipa_dual"]
            .map { Milestone(id:$0.0, label:$0.1, purpose:"按游戏文件出直连着色器库。", expected:nil) }
        let now = Date().timeIntervalSince1970
        var running = TaskRecord(id:"run-1", operation:"ipa", state:"running", gameId:gid)
        running.milestones = plan; running.milestone = "direct"
        running.milestoneStarted = ["unpack":now - 1200, "refresh":now - 1180, "direct":now - 1020]
        running.counters = [TaskCounter(name:"直连库·翻译 + 编库", done:12345, total:23502, rate:7.6)]
        let logs = temp.appendingPathComponent("logs"); try FileManager.default.createDirectory(at:logs, withIntermediateDirectories:true)
        try ((0..<10).map { "[08:5\($0):19]    … 刷新进行中，已用 \(3 + $0) 分；刷新各阶段 7/10；直连库 2/6" }.joined(separator:"\n") + "\n[08:57:49]    … 刷新进行中，已用 13 分 2 秒；直连库·翻译 + 编库 12345/23502\n").write(to:logs.appendingPathComponent("run-1-ipa.log"), atomically:true, encoding:.utf8)
        var cancelled = TaskRecord(id:"end-1", operation:"build", state:"cancelled", gameId:gid); cancelled.message = "已让位给 iPhone 出包，出完会自动接着准备（做完的阶段不重做）。"; cancelled.ended = now - 900
        var imported = TaskRecord(id:"end-2", operation:"import", state:"completed"); imported.message = "操作完成"; imported.ended = now - 1300
        var keys = TaskRecord(id:"end-3", operation:"keys", state:"completed"); keys.message = "操作完成"; keys.ended = now - 1400
        store.tasks = [running, cancelled, imported, keys]
        store.selection = "tasks"; store.showOnboarding = false
        XCTAssertEqual(store.logTail(for:running, lines:3).last, "… 刷新进行中，已用 13 分 2 秒；直连库·翻译 + 编库 12345/23502", "日志末行去掉行首时刻")
        XCTAssertEqual(running.counters?.first?.remaining.map { Int($0) }, Int((23502.0 - 12345.0) / 7.6), "预计剩余 = 剩余项数 ÷ 每秒速度（手算）")
        let previous = Localization.preference
        defer { Localization.preference = previous }
        for (language, tag) in [(AppLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            Localization.preference = language
            let view = NSHostingView(rootView:ContentView().environmentObject(store))
            view.frame = NSRect(x:0, y:0, width:1400, height:900); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds, to:bitmap)
            let png = try XCTUnwrap(bitmap.representation(using:.png, properties:[:]))
            if let out = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] { try png.write(to:URL(fileURLWithPath:out).appendingPathComponent("tasks_\(tag).png")) }
        }
        // 出包成功：完成页（游戏、用时、画面模式、IPA / 资源包大小、包号、各阶段用时、装机三步）
        let out = temp.appendingPathComponent("out"); let app = out.appendingPathComponent("Payload/S2Arm.app")
        try FileManager.default.createDirectory(at:app, withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"com.s2arm.t", "S2AGraphicsMode":"direct", "S2ABuildID":"5b2552318-1c322069"], format:.xml, options:0).write(to:app.appendingPathComponent("Info.plist"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath:"/usr/bin/zip"); zip.currentDirectoryURL = out; zip.arguments = ["-qr", "t.ipa", "Payload"]; try zip.run(); zip.waitUntilExit()
        let pack = out.appendingPathComponent("t资源包"); try FileManager.default.createDirectory(at:pack, withIntermediateDirectories:true)
        try "romfs/a\t5000000000\tx\nshaders/b\t1200000000\ty\n".write(to:pack.appendingPathComponent("index.tsv"), atomically:true, encoding:.utf8)
        var done = TaskRecord(id:"ipa-done", operation:"ipa", state:"completed", gameId:gid); done.milestones = plan; done.ipaPath = out.appendingPathComponent("t.ipa").path; done.outputPath = out.path
        done.started = now - 3125; done.ended = now - 60
        done.milestoneStarted = ["unpack":now - 3125, "refresh":now - 3106, "direct":now - 3020, "ipa":now - 307]
        UserDefaults.standard.removeObject(forKey:"tasks.completionHeroDismissed")
        store.tasks = [done, cancelled, imported, keys]
        XCTAssertEqual(store.completionHeroTask?.id, "ipa-done", "最近一次打 iPhone 包成功 → 完成页")
        XCTAssertEqual(PackFacts.read(ipa:done.ipaPath).packFiles, 2, "资源包文件数按 index.tsv 行数")
        for (language, tag) in [(AppLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            Localization.preference = language
            let view = NSHostingView(rootView:ContentView().environmentObject(store))
            view.frame = NSRect(x:0, y:0, width:1400, height:960); view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.6))   // 完成页后台读 IPA / 资源包大小
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds, to:bitmap)
            if let o = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] { try XCTUnwrap(bitmap.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:o).appendingPathComponent("tasks_done_\(tag).png")) }
        }
        store.dismissCompletionHero(done)
        XCTAssertNil(store.completionHeroTask, "收起后不再显示")
        // 左栏部件单独渲染（侧栏在离屏渲染里是系统材质、画不出来）：logo 按系统图标连续圆角裁切、当前任务卡片带主计数
        Localization.preference = .simplifiedChinese
        let side = NSHostingView(rootView:VStack(alignment:.leading, spacing:16) { BrandMark(); SidebarTaskCard(task:running).environmentObject(store) }.padding(20).frame(width:240).background(Color.gray.opacity(0.15)))
        side.frame = NSRect(x:0, y:0, width:240, height:260); side.layoutSubtreeIfNeeded()
        let sb = try XCTUnwrap(side.bitmapImageRepForCachingDisplay(in:side.bounds)); side.cacheDisplay(in:side.bounds, to:sb)
        if let out = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] { try XCTUnwrap(sb.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:out).appendingPathComponent("sidebar_parts.png")) }
    }
}
