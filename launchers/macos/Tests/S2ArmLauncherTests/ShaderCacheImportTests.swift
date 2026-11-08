import XCTest
@testable import S2ArmLauncher

// 导入客体着色器缓存（10-27）：认 yuzu 系 *.bin（头 8 字节 yuzucach）与 Ryujinx 目录（shared / guest 的 toc + data 四件），
//   不收 vulkan_pipelines.bin 与认不出的；拷进 <数据目录>/着色器缓存/<程序号大写>/，同名替换。期望按规则手写
final class ShaderCacheImportTests: XCTestCase {
    func testClassifyImportListClear() throws {
        let fm = FileManager.default, t = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:t) }
        let src = t.appendingPathComponent("src"), root = t.appendingPathComponent("root")
        try fm.createDirectory(at:src, withIntermediateDirectories:true)
        let yuzu = src.appendingPathComponent("vulkan.bin"); try (Data("yuzucach".utf8) + Data(repeating:7, count:100)).write(to:yuzu)
        let driver = src.appendingPathComponent("vulkan_pipelines.bin"); try Data("yuzucach".utf8).write(to:driver)
        let bogus = src.appendingPathComponent("opengl.bin"); try Data("notacache".utf8).write(to:bogus)
        let ryu = src.appendingPathComponent("ryujinx_cache"); try fm.createDirectory(at:ryu, withIntermediateDirectories:true)
        for n in ["shared.toc", "shared.data", "guest.toc", "guest.data"] { try Data(n.utf8).write(to:ryu.appendingPathComponent(n)) }
        let half = src.appendingPathComponent("half"); try fm.createDirectory(at:half, withIntermediateDirectories:true)
        try Data().write(to:half.appendingPathComponent("shared.toc"))
        XCTAssertEqual(ShaderCacheImport.kind(of:yuzu), .yuzu)
        XCTAssertEqual(ShaderCacheImport.kind(of:driver), .driverCache, "驱动侧缓存即使头对也不收")
        XCTAssertEqual(ShaderCacheImport.kind(of:bogus), .unknown)
        XCTAssertEqual(ShaderCacheImport.kind(of:ryu), .ryujinx)
        XCTAssertEqual(ShaderCacheImport.kind(of:half), .unknown, "四件不齐不算")
        let r = ShaderCacheImport.importItems([yuzu, driver, bogus, ryu, half], root:root, gameId:"0100f2c0115b6000")
        XCTAssertEqual(Set(r.imported), ["vulkan.bin", "ryujinx_cache"])
        XCTAssertEqual(r.skipped.count, 3)
        XCTAssertTrue(r.skipped.contains { $0.hasPrefix("vulkan_pipelines.bin") && $0.contains("不需要") })
        let dest = root.appendingPathComponent("着色器缓存/0100F2C0115B6000")
        XCTAssertTrue(fm.fileExists(atPath:dest.appendingPathComponent("ryujinx_cache/guest.data").path), "程序号转大写、目录整个拷")
        XCTAssertEqual(ShaderCacheImport.list(root:root, gameId:"0100F2C0115B6000").map(\.name), ["ryujinx_cache", "vulkan.bin"])
        XCTAssertEqual(ShaderCacheImport.list(root:root, gameId:"0100F2C0115B6000").first { $0.name == "vulkan.bin" }?.bytes, 108)
        try (Data("yuzucach".utf8) + Data(repeating:1, count:10)).write(to:yuzu)
        _ = ShaderCacheImport.importItems([yuzu], root:root, gameId:"0100F2C0115B6000")
        XCTAssertEqual(ShaderCacheImport.list(root:root, gameId:"0100F2C0115B6000").first { $0.name == "vulkan.bin" }?.bytes, 18, "同名替换")
        try ShaderCacheImport.clear(root:root, gameId:"0100F2C0115B6000")
        XCTAssertTrue(ShaderCacheImport.list(root:root, gameId:"0100F2C0115B6000").isEmpty)
        XCTAssertNoThrow(try ShaderCacheImport.clear(root:root, gameId:"0100F2C0115B6000"), "本来就没有不算失败")
    }

    // 审计 18:00 P2-35：删不掉要抛错、文件留在盘上（原先 try? 吞掉，界面清成空）。期望手算：程序号目录设 0555，
    //   里面的 vulkan.bin 删不掉 → clear 抛错，list 仍是 ["vulkan.bin"]
    func testClearFailureThrowsAndKeepsFiles() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = ShaderCacheImport.folder(root:root, gameId:"0100000000000000")
        try fm.createDirectory(at:dir, withIntermediateDirectories:true)
        try Data("yuzucach".utf8).write(to:dir.appendingPathComponent("vulkan.bin"))
        try fm.setAttributes([.posixPermissions:0o555], ofItemAtPath:dir.path)
        defer { try? fm.setAttributes([.posixPermissions:0o755], ofItemAtPath:dir.path); try? fm.removeItem(at:root) }
        XCTAssertThrowsError(try ShaderCacheImport.clear(root:root, gameId:"0100000000000000"))
        XCTAssertEqual(ShaderCacheImport.list(root:root, gameId:"0100000000000000").map(\.name), ["vulkan.bin"])
    }
}
