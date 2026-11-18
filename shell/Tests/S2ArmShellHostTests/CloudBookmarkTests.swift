import Foundation
import Testing
@testable import S2ArmShellHost

// 云存档书签解析（诊断 D-4Y69）：和系统文件服务的连接中断 / 失效（NSCocoaErrorDomain 4097 / 4099）是瞬时故障，重试一次；
//   期望手写：第一次 4097、第二次成功 → 拿到地址、调了 2 次；4099 同理；别的错（257 没权限）→ 原样抛、只调 1 次；连续两次 4097 → 抛


@Test func bookmarkRetriesOnceWhenFileServiceConnectionDrops() throws {
    for code in [4097, 4099] {
        var calls = 0
        var stale = false
        let url = try CloudSaves.resolveBookmark(Data([1]), stale: &stale) { _, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: NSCocoaErrorDomain, code: code) }
            return URL(fileURLWithPath: "/tmp/saves")
        }
        #expect(url.path == "/tmp/saves")
        #expect(calls == 2)
    }
}

@Test func bookmarkDoesNotRetryOtherErrors() {
    var calls = 0
    var stale = false
    #expect(throws: NSError.self) {
        _ = try CloudSaves.resolveBookmark(Data([1]), stale: &stale) { _, _ in calls += 1; throw NSError(domain: NSCocoaErrorDomain, code: 257) }
    }
    #expect(calls == 1)
}

@Test func bookmarkGivesUpAfterSecondInterruption() {
    var calls = 0
    var stale = false
    #expect(throws: NSError.self) {
        _ = try CloudSaves.resolveBookmark(Data([1]), stale: &stale) { _, _ in calls += 1; throw NSError(domain: NSCocoaErrorDomain, code: 4097) }
    }
    #expect(calls == 2)
}
