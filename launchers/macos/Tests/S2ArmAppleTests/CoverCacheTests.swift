import XCTest
import AppKit
@testable import NX2AppleUI

// 剃刀 M15：封面缓存按「路径 + 修改时间」认，同一路径的文件换了（玩家换封面、后台查到横图）就重新解码；期望手写：先 2×2、换成 4×4 后拿到 4×4
@MainActor final class CoverCacheTests: XCTestCase {
    private func png(_ side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func waitFor(_ cache: CoverCache, _ path: String, side: Int?) async throws {
        for _ in 0..<100 {
            if cache.image(path)?.representations.first?.pixelsWide == side { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("封面加载结果未更新到 \(String(describing: side))")
    }

    func testSamePathNewFileIsDecodedAgain() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-cover-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = CoverCache()
        try png(2).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        try await waitFor(cache, file.path, side: 2)
        try png(4).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file.path)
        try await waitFor(cache, file.path, side: 4)
        try FileManager.default.removeItem(at: file)
        try await waitFor(cache, file.path, side: nil)
    }

    func testLinkedCoverTracksTheTargetTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-cover-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.png")
        let link = root.appendingPathComponent("cover.png")
        try png(2).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = CoverCache()
        try await waitFor(cache, link.path, side: 2)
        try png(4).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: target.path)
        try await waitFor(cache, link.path, side: 4)
    }

    func testSlowArtworkDoesNotBlockTheUIOrQueueDuplicateLoads() async throws {
        let started = expectation(description: "background loader started")
        let release = DispatchSemaphore(value: 0)
        let cache = CoverCache(loader: { _, previous in
            if previous == nil {
                XCTAssertFalse(Thread.isMainThread, "文件读取不能发生在 UI 线程")
                started.fulfill()
                _ = release.wait(timeout: .now() + 0.5)
            }
            return CoverCache.Loaded(version: "fixture", image: NSImage(size: NSSize(width: 2, height: 2)))
        })
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { XCTAssertNil(cache.image("slow-artwork")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 0.1, "慢图片不能阻塞视图读取缓存")
        await fulfillment(of: [started], timeout: 1)
        release.signal()
        for _ in 0..<100 where cache.image("slow-artwork") == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(cache.image("slow-artwork"))
    }
}
