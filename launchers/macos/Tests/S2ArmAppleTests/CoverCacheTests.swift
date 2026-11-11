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

    func testSamePathNewFileIsDecodedAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-cover-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = CoverCache()
        try png(2).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        XCTAssertEqual(cache.image(file.path)?.representations.first?.pixelsWide, 2)
        try png(4).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file.path)
        XCTAssertEqual(cache.image(file.path)?.representations.first?.pixelsWide, 4, "换了文件要拿到新图")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(cache.image(file.path), "文件没了不显示旧图")
    }
}
