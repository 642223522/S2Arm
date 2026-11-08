import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 出包流程的适配层部分：平台勾选（顺序、未开放不算、记住）、里程碑轨迹（plan / 当前步 / 每步实际用时）、游戏原件信息。期望值手算。
final class ExportFlowTests: XCTestCase {
    func testPickedFollowsPageOrderAndDropsUnreleased() {
        // 存的顺序是 mac、android、ios：排队按页面顺序 iPhone / iPad → macOS；安卓没开放，存了也不算
        XCTAssertEqual(ExportPlatform.picked(["mac", "android", "ios"]), [.ios, .mac])
        XCTAssertEqual(ExportPlatform.picked([]), [])
        XCTAssertEqual(ExportPlatform.allCases.filter(\.released), [.ios, .mac])
    }

    func testToggleIgnoresUnreleased() {
        XCTAssertEqual(ExportPlatform.toggled([], .mac), ["mac"])
        XCTAssertEqual(ExportPlatform.toggled(["mac", "ios"], .mac), ["ios"])
        XCTAssertEqual(ExportPlatform.toggled(["ios"], .ohos), ["ios"])   // 鸿蒙置灰：点了不变
    }

    func testExportTargetsDefaultNoneThenOldLauncherThenOwnFile() throws {
        let box = try Sandbox(); defer { box.remove() }
        let fresh = SettingsProvider(client: client(box, FakeRunner()))
        XCTAssertEqual(fresh.exportTargets, [])   // 缺省一个都不勾（维护者 11-02）
        var env = box.environment(); env.exportTargets = ["ios"]
        let c = client(box, FakeRunner(), env: env)
        let settings = SettingsProvider(client: c)
        XCTAssertEqual(settings.exportTargets, ["ios"])   // 新前端没存过：接着用旧启动器的勾选
        try settings.setExportTargets(["ios", "mac"])
        XCTAssertEqual(SettingsProvider(client: c).exportTargets, ["ios", "mac"])   // 重开还在
    }

    private func event(_ type: String, _ fields: [String: Any]) -> EngineEvent {
        EngineEvent(ev: type, t: 0, code: nil, severity: .info, fields: fields)
    }

    func testTrackRecordsStepStartsAndDurations() {
        var track = MilestoneTrack()
        let plan: [[String: Any]] = [["id": "unpack", "label": "解包", "purpose": "", "expected": 10, "source": "history", "samples": 2],
                                     ["id": "refresh", "label": "改写与准备资源", "purpose": "", "expected": NSNull(), "source": "none", "samples": 0],
                                     ["id": "direct", "label": "直连着色器库", "purpose": "", "expected": NSNull(), "source": "none", "samples": 0],
                                     ["id": "ipa", "label": "编 App 与签名", "purpose": "", "expected": NSNull(), "source": "none", "samples": 0]]
        track.ingest(event("plan", ["milestones": plan]), now: 100)
        XCTAssertEqual(track.plan.map(\.id), ["unpack", "refresh", "direct", "ipa"])
        XCTAssertEqual(track.plan[0].measured, 10)
        XCTAssertNil(track.plan[1].measured)
        XCTAssertNil(track.index)
        track.ingest(event("stage", ["milestone": "unpack"]), now: 100)
        track.ingest(event("progress", ["milestone": "unpack"]), now: 104)   // 同一步的后续事件不改开始时刻
        track.ingest(event("stage", ["milestone": "refresh"]), now: 130)
        // direct 没进过（跳过）：refresh 结束于 ipa 开始
        track.ingest(event("stage", ["milestone": "ipa"]), now: 190)
        XCTAssertEqual(track.index, 3)
        XCTAssertEqual(track.duration("unpack"), 30)
        XCTAssertEqual(track.duration("refresh"), 60)
        XCTAssertNil(track.duration("direct"))
        XCTAssertNil(track.duration("ipa"))   // 还在做
        track.finish(at: 250)
        XCTAssertEqual(track.duration("ipa"), 60)
        // 整单预计：当前步 ipa 没有本机记录 → 不给（不编数字）
        XCTAssertNil(track.estimate(fraction: nil, now: 200).remaining)
        XCTAssertEqual(track.estimate(fraction: nil, now: 200).totalElapsed, 100)
    }

    func testCatalogPackagesBecomeGameInfo() {
        let g = GameSummary(catalog: ["id": "0100A", "name": "Alpha", "packages": [
            ["type": "base", "titleId": "0100A000", "version": 0, "display": "1.0.0", "size": 1000, "sha256": "a"],
            ["type": "update", "titleId": "0100A800", "version": 65536, "display": "1.0.1", "size": 200, "sha256": "b"],
            ["type": "update", "titleId": "0100A800", "version": 131072, "display": "", "size": 300, "sha256": "c"],
            ["type": "dlc", "titleId": "0100A001", "version": 0, "display": "", "size": 50, "sha256": "d"],
            ["type": "dlc", "titleId": "0100A001", "version": 0, "display": "", "size": 50, "sha256": "d"],   // 同一个文件里的同一项
            ["type": "dlc", "titleId": "0100A002", "version": 0, "display": "", "size": 70, "sha256": "e"]]])!
        XCTAssertEqual(g.version("base"), "1.0.0")
        XCTAssertEqual(g.version("update"), "v131072")   // 最新的那个；没有显示版本写 v + 版本号
        XCTAssertNil(g.version("patch"))
        XCTAssertEqual(g.dlcCount, 2)
        XCTAssertEqual(g.totalBytes, 1000 + 200 + 300 + 50 + 70)
    }

    func testReemittedPlanKeepsStartedTimes() {
        // 作业层改标复用后重发同一组步：只换预计，已走的时间照留；换了一组步才从头记
        var track = MilestoneTrack()
        let plan: [[String: Any]] = [["id": "unpack", "label": "解包", "purpose": "", "expected": 10, "source": "history", "samples": 2],
                                     ["id": "direct", "label": "直连着色器库", "purpose": "", "expected": 600, "source": "history", "samples": 3]]
        track.ingest(event("plan", ["milestones": plan]), now: 0)
        track.ingest(event("stage", ["milestone": "unpack"]), now: 5)
        var again = plan; again[1] = ["id": "direct", "label": "直连着色器库", "purpose": "", "expected": 0, "source": "reuse", "samples": 0, "reuse": true]
        track.ingest(event("plan", ["milestones": again, "milestone": "unpack"]), now: 9)
        XCTAssertEqual(track.started["unpack"], 5)
        XCTAssertEqual(track.plan[1].reuse, true)
        XCTAssertEqual(track.estimate(fraction: nil, now: 9).remaining!, 6, accuracy: 1e-9)   // 解包剩 10 − 4，直连库 0
        track.ingest(event("plan", ["milestones": [plan[0]]]), now: 20)
        XCTAssertEqual(track.started, [:])
    }
}
