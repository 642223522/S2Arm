// 导入玩家自己的客体着色器缓存（10-27 着色器线接口，出包侧 docs/客体着色器缓存导入.md）：只把玩家经文件面板选中的文件 / 目录拷进
//   <数据目录>/着色器缓存/<程序号大写>/，下次打包 / 刷新时自动并入通用模式的离线库（缓存内容指纹进键）；不读原路径以外的东西（10-26 读 ~/Downloads 弹过授权框）。
//   认得：yuzu 系（yuzu / Eden / suyu / sudachi）的 *.bin，文件头 8 字节 "yuzucach"；Ryujinx 新格式目录（shared.toc / shared.data / guest.toc / guest.data）。
//   vulkan_pipelines.bin（显卡驱动侧缓存）没用，直接不收。
import Foundation

enum ShaderCacheImport {
    enum Kind: Equatable { case yuzu, ryujinx, driverCache, unknown }

    static func kind(of url: URL) -> Kind {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath:url.path, isDirectory:&dir) else { return .unknown }
        if dir.boolValue {
            let need = ["shared.toc", "shared.data", "guest.toc", "guest.data"]
            return need.allSatisfy { FileManager.default.fileExists(atPath:url.appendingPathComponent($0).path) } ? .ryujinx : .unknown
        }
        if url.lastPathComponent.lowercased() == "vulkan_pipelines.bin" { return .driverCache }
        guard url.pathExtension.lowercased() == "bin", let h = try? FileHandle(forReadingFrom:url) else { return .unknown }
        defer { try? h.close() }
        return (try? h.read(upToCount:8)) == Data("yuzucach".utf8) ? .yuzu : .unknown
    }

    static func folder(root: URL, gameId: String) -> URL {
        root.appendingPathComponent("着色器缓存", isDirectory:true).appendingPathComponent(gameId.uppercased(), isDirectory:true)
    }

    /// 拷进去；同名的先删再拷（换新缓存）。返回（导入了的名字，跳过的「名字：原因」）
    static func importItems(_ urls: [URL], root: URL, gameId: String) -> (imported: [String], skipped: [String]) {
        let fm = FileManager.default, dest = folder(root:root, gameId:gameId)
        var imported: [String] = [], skipped: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            switch kind(of:url) {
            case .driverCache: skipped.append(name + L("：这是显卡驱动的管线缓存，不需要"))
            case .unknown: skipped.append(name + L("：认不出（要 yuzu 系的 *.bin，或含 shared.toc / guest.toc 的 Ryujinx 缓存目录）"))
            case .yuzu, .ryujinx:
                do {
                    try fm.createDirectory(at:dest, withIntermediateDirectories:true)
                    let target = dest.appendingPathComponent(name)
                    if fm.fileExists(atPath:target.path) { try fm.removeItem(at:target) }
                    try fm.copyItem(at:url, to:target)
                    imported.append(name)
                } catch { skipped.append(name + L("：拷贝失败（") + error.localizedDescription + L("）")) }
            }
        }
        return (imported, skipped)
    }

    /// 已导入的（名字、字节数）
    static func list(root: URL, gameId: String) -> [(name: String, bytes: Int64)] {
        let fm = FileManager.default, dest = folder(root:root, gameId:gameId)
        let names = ((try? fm.contentsOfDirectory(atPath:dest.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.map { n in
            let u = dest.appendingPathComponent(n)
            let files = fm.enumerator(at:u, includingPropertiesForKeys:[.fileSizeKey]).map { Array($0.compactMap { $0 as? URL }) } ?? []
            let size = (files.isEmpty ? [u] : files).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
            return (n, size)
        }
    }

    /// 删失败照实抛出（审计 18:00 P2-35：原先 try? 吞掉，界面把列表清空、文件还在）；本来就没有不算失败
    static func clear(root: URL, gameId: String) throws {
        let dest = folder(root:root, gameId:gameId)
        guard FileManager.default.fileExists(atPath:dest.path) else { return }
        try FileManager.default.removeItem(at:dest)
    }
}
