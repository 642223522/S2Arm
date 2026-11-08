import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 作业页的「12.3 MB/s」：速度来自本计数器的实测增量（11-08 iOS 平台组件改成按字节报进度）。
/// 期望值手算：1.00 GB → 1.03 GB，用了 3 秒 → 10 MB/s。
final class JobProgressTests: XCTestCase {
    private func progress(_ t: Double, done: Double, total: Double = 8_320_000_000) -> EngineEvent {
        EngineEvent(ev: "progress", t: t, code: nil, severity: .info,
                    fields: ["stage": "下载 Xcode 的 iOS 平台组件（约 8 GB）", "done": done, "total": total, "unit": "B"])
    }

    func test_rate_appears_after_two_seconds_and_is_bytes_per_second() {
        var p = JobProgress()
        p.ingest(progress(0, done: 1_000_000_000))
        XCTAssertEqual(p.rateText, "")                       // 量不够两秒：不编数
        p.ingest(progress(3, done: 1_030_000_000))
        XCTAssertEqual(p.rate ?? 0, 10_000_000, accuracy: 1)
        XCTAssertTrue(p.rateText.hasSuffix("/s"))
        XCTAssertTrue(p.rateText.hasPrefix("10"))
        XCTAssertEqual(p.fraction ?? 0, 1_030_000_000 / 8_320_000_000, accuracy: 1e-9)
    }

    func test_rate_resets_when_the_counter_restarts() {
        var p = JobProgress()
        p.ingest(progress(0, done: 1_000_000_000))
        p.ingest(progress(3, done: 1_030_000_000))
        p.ingest(progress(4, done: 10_000_000))               // 换了个从头数起的计数器
        XCTAssertNil(p.rate)
        XCTAssertEqual(p.rateText, "")
    }
}
