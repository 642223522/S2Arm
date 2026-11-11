import XCTest
import S2ArmAppleAdapter

/// 里程碑进度推算：期望值手算
final class MilestoneTests: XCTestCase {
    let plan = [Milestone(id: "a", label: "A", purpose: "", expected: 100, source: "history", samples: 3),
                Milestone(id: "b", label: "B", purpose: "", expected: 200, source: "history", samples: 5),
                Milestone(id: "c", label: "C", purpose: "", expected: 300, source: "history", samples: 4)]

    func testRateFromRealCounts() {
        // 剃刀 M20：本步剩余只用调用方给的实测速率值（measuredStep）。a 用了 100 秒（= 预计，校准 1）；b 实测还剩 120 → 本步 120；之后 c 300 → 共 420
        let e = MilestoneEstimate(plan: plan, current: "b", started: ["a": 0, "b": 100], fraction: 0.25, measuredStep: 120, now: 150)
        XCTAssertEqual(e.calibration, 1, accuracy: 1e-9)
        XCTAssertEqual(e.stepRemainingByRate!, 120, accuracy: 1e-9)
        XCTAssertEqual(e.remaining!, 420, accuracy: 1e-9)
        XCTAssertEqual(e.fill(0), 1); XCTAssertEqual(e.fill(1), 0.25, accuracy: 1e-9); XCTAssertEqual(e.fill(2), 0)
        // 有完成比例但没有实测速率（刚开工、量不够两秒）：不再按「已用 × 未完成 ÷ 完成」另算一份，本步按历史兜底 200 − 50 = 150，共 450
        let early = MilestoneEstimate(plan: plan, current: "b", started: ["a": 0, "b": 100], fraction: 0.25, now: 150)
        XCTAssertNil(early.stepRemainingByRate)
        XCTAssertEqual(early.remaining!, 450, accuracy: 1e-9)
    }
    func testNoCountsUsesExpectedMinusElapsed() {
        // a 用了 200 秒（预计 100）→ 校准 2；b 已用 100 秒、无计数 → 本步剩 200×2−100 = 300；c 300×2 = 600 → 共 900
        let e = MilestoneEstimate(plan: plan, current: "b", started: ["a": 0, "b": 200], fraction: nil, now: 300)
        XCTAssertEqual(e.calibration, 2, accuracy: 1e-9)
        XCTAssertEqual(e.remaining!, 900, accuracy: 1e-9)
        XCTAssertEqual(e.fill(1), 0.25, accuracy: 1e-9)   // 100 ÷ (200×2)
    }
    func testOverrunNeverShowsZero() {
        // c 预计 300（校准 1）、已用 1000 秒、无计数 → 剩余至少预计的 10% = 30；填充最多 0.95
        let e = MilestoneEstimate(plan: plan, current: "c", started: ["a": 0, "b": 100, "c": 300], fraction: nil, now: 1300)
        XCTAssertEqual(e.remaining!, 30, accuracy: 1e-9)
        XCTAssertEqual(e.fill(2), 0.95, accuracy: 1e-9)
        XCTAssertEqual(e.totalElapsed, 1300, accuracy: 1e-9)
    }
    func testCalibrationClamped() {
        // a 用了 1000 秒（预计 100，比值 10）→ 夹到 3
        let e = MilestoneEstimate(plan: plan, current: "b", started: ["a": 0, "b": 1000], fraction: nil, now: 1000)
        XCTAssertEqual(e.calibration, 3, accuracy: 1e-9)
    }
    func testHistorySamplesIsSmallestOfRemainingSteps() {
        // 当前 b 起：b 5 条、c 4 条 → 写「最近 4 次」
        let e = MilestoneEstimate(plan: plan, current: "b", started: ["a": 0, "b": 100], fraction: nil, now: 150)
        XCTAssertEqual(e.historySamples, 4)
    }
    func testNoLocalHistoryNeverEstimatesTotal() {
        // 本机没有记录（none）或老任务的缺省值（default）：整单预计一律不给；本步有真实完成数时只给按速度的本步剩余
        let none = plan.map { Milestone(id: $0.id, label: $0.label, purpose: "", expected: nil, source: "none", samples: 0) }
        let e = MilestoneEstimate(plan: none, current: "b", started: ["a": 0, "b": 100], fraction: 0.25, measuredStep: 80, now: 150)
        XCTAssertNil(e.remaining)
        XCTAssertEqual(e.stepRemainingByRate!, 80, accuracy: 1e-9)   // 实测值原样
        let old = plan.map { Milestone(id: $0.id, label: $0.label, purpose: "", expected: $0.expected, source: "default", samples: 0) }
        let o = MilestoneEstimate(plan: old, current: "b", started: ["a": 0, "b": 100], fraction: nil, now: 150)
        XCTAssertNil(o.remaining); XCTAssertNil(o.stepRemainingByRate)
        XCTAssertEqual(o.fill(1), 0)   // 没有完成数也没有记录：不按已用 ÷ 缺省值编填充
    }
    func testOneMissingStepDropsTotal() {
        // 后面任何一步没有本机记录（c 缺）就不给整单预计
        var partial = plan; partial[2] = Milestone(id: "c", label: "C", purpose: "", expected: nil, source: "none", samples: 0)
        let e = MilestoneEstimate(plan: partial, current: "b", started: ["a": 0, "b": 100], fraction: 0.25, measuredStep: 80, now: 150)
        XCTAssertNil(e.remaining)
        XCTAssertNotNil(e.stepRemainingByRate)
    }

    func testReusedStepWithoutRecordCountsZero() {
        // 作业层标了复用、本机没有复用记录的步（source = reuse、expected 0）按 0 秒计；整单预计照给，「最近 N 次」只数按历史估的步
        let p = [Milestone(id: "a", label: "A", purpose: "", expected: 100, source: "history", samples: 3),
                 Milestone(id: "b", label: "B", purpose: "", expected: 0, source: "reuse", samples: 0, reuse: true),
                 Milestone(id: "c", label: "C", purpose: "", expected: 50, source: "history", samples: 4)]
        // a 已用 40 秒、无计数 → 本步剩 100 − 40 = 60；b 0；c 50 → 共 110
        let e = MilestoneEstimate(plan: p, current: "a", started: ["a": 0], fraction: nil, now: 40)
        XCTAssertEqual(p[1].measured, 0)
        XCTAssertEqual(e.remaining!, 110, accuracy: 1e-9)
        XCTAssertEqual(e.historySamples, 3)
        // 只剩复用步：整单 0 秒、没有按历史估的步 → 「最近 N 次」为 0
        let only = MilestoneEstimate(plan: p, current: "b", started: ["a": 0, "b": 100], fraction: nil, now: 100)
        XCTAssertEqual(MilestoneEstimate(plan: [p[1]], current: "b", started: ["b": 0], fraction: nil, now: 3).remaining!, 0, accuracy: 1e-9)
        XCTAssertEqual(only.historySamples, 4)
        XCTAssertEqual(MilestoneEstimate(plan: [p[1]], current: "b", started: ["b": 0], fraction: nil, now: 3).historySamples, 0)
    }

    func testReusedStepWithRecordUsesIt() {
        // 复用步有复用记录（作业层给 source = history、expected = 复用时的中位数）：照历史估，不再是冷出包的几百秒
        let p = [Milestone(id: "d", label: "D", purpose: "", expected: 75, source: "history", samples: 2, reuse: true),
                 Milestone(id: "e", label: "E", purpose: "", expected: 9, source: "history", samples: 5)]
        let e = MilestoneEstimate(plan: p, current: "d", started: ["d": 0], fraction: nil, now: 15)
        XCTAssertEqual(e.remaining!, 75 - 15 + 9, accuracy: 1e-9)
        XCTAssertEqual(e.historySamples, 2)
    }
}
