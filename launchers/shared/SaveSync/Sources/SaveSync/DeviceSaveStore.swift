// 本机偏好存储：Apple TV（tvOS）上代替 iCloud 云盘文件夹的「云端」。
// tvOS 不让 App 写 Documents，游戏与存档在 Library/Caches，系统空间紧时会被清；免费 Apple ID 又没有 iCloud。
// App 偏好（UserDefaults）会留下来：存档打成的 .s2asave 用 LZFSE 压缩后存进偏好；所有存档合计超过 limit（约 900 KB，
// 偏好总量过约 1 MB 系统会 abort）就改写到 Library/Preferences/tv-saves/<键> 普通文件。打包、核对、比新旧仍是 SaveSyncEngine 那一套。
// 做法借自 TVPort（MIT License）dm/ios/SourcesTV/TVSaves.m：LZFSE（速度优先，加密存档压不动的不白花时间）、900 KB 预算、超了落 Library/Preferences 文件。
//
// 一个存储格（slot，如「程序号/玩家」）只放一份：最新的 head 与它的快照。只有这一台 Apple TV 写它。
//   快照先写进「待定」位（pending），putHead 时才转正、替换旧快照：head 没写成，旧 head 和旧快照照旧成对。
import Compression
import CryptoKit
import Foundation

public struct DeviceSaveStore: SaveSyncStore, @unchecked Sendable {
    /// 偏好里所有存档值（head 与快照）合计的上限
    public static let defaultLimit = 900 * 1024
    /// 偏好键前缀：只认这个前缀的值算进预算
    public static let prefix = "S2ASave:"
    static let magic = Data("S2Z1".utf8)

    public let slot: String
    let defaults: UserDefaults
    let spillDirectory: URL
    let limit: Int

    /// slot：不随安装变的名字（程序号 + 存档槽 / 玩家），不能含路径；spillDirectory：超预算时放文件的目录（tvOS 上 Library/Preferences/tv-saves）
    public init(slot: String, defaults: UserDefaults = .standard, spillDirectory: URL, limit: Int = DeviceSaveStore.defaultLimit) {
        self.slot = slot; self.defaults = defaults; self.spillDirectory = spillDirectory; self.limit = limit
    }

    var headKey: String { Self.prefix + slot + ".head" }
    var snapKey: String { Self.prefix + slot + ".snap" }
    var pendingKey: String { Self.prefix + slot + ".pending" }
    func spillURL(_ key: String) -> URL {
        spillDirectory.appendingPathComponent(String(key.dropFirst(Self.prefix.count)).replacingOccurrences(of: "/", with: "_"))
    }

    // MARK: 压缩记录：「S2Z1」+ 原长（u64 小端）+ 快照名长（u16 小端）+ 快照名 + LZFSE 数据

    static func pack(_ raw: Data, name: String) throws -> Data {
        let nameData = Data(name.utf8)
        guard nameData.count <= Int(UInt16.max) else { throw DeviceSaveStoreError.write(name) }
        var out = magic
        withUnsafeBytes(of: UInt64(raw.count).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(nameData.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(nameData)
        if raw.isEmpty { return out }
        let room = raw.count + raw.count / 8 + 65536   // 压不动的会变大；放不下时编码器报 0 而不是越界
        var z = Data(count: room)
        let n = z.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, room, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZFSE)
        } }
        guard n > 0 else { throw DeviceSaveStoreError.write(name) }
        out.append(z.prefix(n))
        return out
    }

    /// 解开一条记录：回 (快照名, 原数据)；头不对、长度不对、解不开都报 corrupt（不崩）
    static func unpack(_ record: Data, key: String) throws -> (name: String, data: Data) {
        let r = Data(record)   // 下标从 0 起
        let head = magic.count + 8 + 2
        guard r.count >= head, r.prefix(magic.count) == magic else { throw SaveSyncError.corrupt(key) }
        let size = r[magic.count..<magic.count + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let nameLen = Int(r[magic.count + 8]) | Int(r[magic.count + 9]) << 8
        guard r.count >= head + nameLen, size <= UInt64(Int.max / 2),
              let name = String(data: r[head..<head + nameLen], encoding: .utf8) else { throw SaveSyncError.corrupt(key) }
        let payload = r[(head + nameLen)...]
        if size == 0 { guard payload.isEmpty else { throw SaveSyncError.corrupt(key) }; return (name, Data()) }
        guard !payload.isEmpty else { throw SaveSyncError.corrupt(key) }
        var raw = Data(count: Int(size))
        let n = raw.withUnsafeMutableBytes { dst in payload.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(size), src.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_LZFSE)
        } }
        guard n == Int(size) else { throw SaveSyncError.corrupt(key) }
        return (name, raw)
    }

    // MARK: 读写一条值（偏好或落文件）

    /// 偏好里本前缀下、除 keys 以外所有值的字节数
    func usedBytes(excluding keys: Set<String>) -> Int {
        defaults.dictionaryRepresentation().reduce(0) { sum, entry in
            guard entry.key.hasPrefix(Self.prefix), !keys.contains(entry.key) else { return sum }
            switch entry.value {
            case let d as Data: return sum + d.count
            case let s as String: return sum + s.utf8.count
            default: return sum
            }
        }
    }

    /// 写一条：放得进预算写偏好（并删掉同名落文件），放不进写文件（并删掉偏好里的）。replacing：这次写完就会腾出来的键，不算进预算
    func write(_ data: Data, key: String, replacing: Set<String> = []) throws {
        let spill = spillURL(key)
        if usedBytes(excluding: replacing.union([key])) + data.count > limit {
            try FileManager.default.createDirectory(at: spillDirectory, withIntermediateDirectories: true)
            do { try data.write(to: spill, options: .atomic) } catch { throw DeviceSaveStoreError.write(key) }
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(data, forKey: key)
            try? FileManager.default.removeItem(at: spill)
        }
    }
    func read(_ key: String) -> Data? { defaults.data(forKey: key) ?? (try? Data(contentsOf: spillURL(key))) }
    func remove(_ key: String) { defaults.removeObject(forKey: key); try? FileManager.default.removeItem(at: spillURL(key)) }
    /// 这条现在在哪：偏好 / 文件 / 没有（单测与日志用）
    public enum Place: Equatable { case preferences, file, none }
    public func place(of key: String) -> Place {
        if defaults.data(forKey: key) != nil { return .preferences }
        return FileManager.default.fileExists(atPath: spillURL(key).path) ? .file : .none
    }
    public var snapshotPlace: Place { place(of: snapKey) }

    // MARK: SaveSyncStore

    public func heads() throws -> [SaveHead] {
        guard let data = read(headKey), let head = try? CloudSaveFolder.decoder.decode(SaveHead.self, from: data) else { return [] }
        return [head]
    }

    public func download(_ head: SaveHead, to destination: URL) throws {
        guard let record = read(snapKey) else { throw SaveSyncError.corrupt(head.snapshot) }
        let (name, raw) = try Self.unpack(record, key: head.snapshot)
        guard name == head.snapshot else { throw SaveSyncError.corrupt(head.snapshot) }
        try raw.write(to: destination, options: .withoutOverwriting)
        guard try sha256File(destination) == head.archiveSha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw SaveSyncError.corrupt(head.snapshot)
        }
    }

    public func putSnapshot(_ archive: URL, as snapshot: String, sha256: String) throws {
        let raw = try Data(contentsOf: archive)
        let record = try Self.pack(raw, name: snapshot)
        try write(record, key: pendingKey)
        // 读回核一遍：存进去的就是这一份
        guard let back = read(pendingKey), let (name, data) = try? Self.unpack(back, key: snapshot), name == snapshot,
              sha256Data(data) == sha256 else {
            remove(pendingKey)
            throw SaveSyncError.corrupt(snapshot)
        }
    }

    /// 转正待定快照（head 指着它时），再写 head；head 指的是现有快照（取回别处版本后写本机 head）就只写 head
    public func putHead(_ head: SaveHead) throws {
        let data = try CloudSaveFolder.encoder.encode(head)
        if let pending = read(pendingKey), let name = try? Self.unpack(pending, key: head.snapshot).name, name == head.snapshot {
            // 新快照整条替换旧的（偏好里同键替换、文件原子替换）；待定那份马上删，不算进预算。写不成旧快照和旧 head 照旧成对
            try write(pending, key: snapKey, replacing: [pendingKey])
            remove(pendingKey)
        }
        try write(data, key: headKey)
    }

    /// 只有一格：putHead 时旧快照已经换掉，这里只清没转正的待定快照
    public func prune(device: String, keep: Int, heads: [SaveHead]) { remove(pendingKey) }
}

public enum DeviceSaveStoreError: Error, Equatable, LocalizedError, Sendable {
    /// 写不进偏好也写不进文件（键）
    case write(String)
    public var errorDescription: String? {
        switch self { case .write(let key): return "SaveSync: couldn’t keep \(key) on this device" }
    }
}

func sha256Data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// 和存档放在一起、会被一起清掉的本机同步状态（tvOS 上 <文档根>/save-sync，在 Library/Caches 里）：本机设备号与各格的基线。
///   Caches 被系统清掉 = 设备号与基线也没了：下次换一个新设备号，偏好里那份 head 就是「别的设备的版本」、本机没有存档，
///   起局前同步按 SaveSync 原规则取回并恢复（decideSaveSync：本地为空、只有一份别处版本 → download）。
///   Caches 还在时设备号不变，自己的 head 不参与判定：只比本机存档和基线，改过就写进偏好（upload）
public struct DeviceSaveState: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// 本机设备号：第一次用时生成，写在 directory/device
    public func device() -> String {
        let url = directory.appendingPathComponent("device")
        if let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
    func baseURL(_ slot: String) -> URL { directory.appendingPathComponent("base-" + slot.replacingOccurrences(of: "/", with: "_") + ".json") }
    public func loadBase(_ slot: String) -> String? { try? String(contentsOf: baseURL(slot), encoding: .utf8) }
    public func storeBase(_ slot: String, _ text: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: baseURL(slot), atomically: true, encoding: .utf8)
    }
}
