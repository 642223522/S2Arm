import Foundation
import Testing
@testable import SaveSync

/// 本机偏好存储（tvOS 存档持久化）。偏好用一次性 suite，落文件目录用临时目录；期望都按输入手推，不跑被测实现算期望。
private final class Fixture: @unchecked Sendable {
    let suite = "s2a-devstore-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var spill: URL { root.appendingPathComponent("tv-saves") }
    func store(_ slot: String = "0100000000000001/first") -> DeviceSaveStore { DeviceSaveStore(slot: slot, defaults: defaults, spillDirectory: spill) }
    func file(_ name: String, _ data: Data) throws -> URL { let u = root.appendingPathComponent(name); try data.write(to: u); return u }
    func head(_ snapshot: String, sha: String, device: String = "dev") -> SaveHead {
        SaveHead(device: device, deviceName: device, snapshot: snapshot, archiveSha256: sha, content: "c", clock: [device: 1],
                 savedAt: Date(timeIntervalSince1970: 0), bytes: 0)
    }
}

private func randomBytes(_ n: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
}

@Test func 压缩往返_能压的存档进偏好且原样取回() throws {
    let f = try Fixture()
    let raw = Data(repeating: 0, count: 2_000_000) + Data("tail".utf8)   // 2 MB 几乎全零：压完远小于 900 KB
    let archive = try f.file("a.s2asave", raw)
    let sha = try sha256File(archive)
    let store = f.store()
    try store.putSnapshot(archive, as: "snap-1", sha256: sha)
    try store.putHead(f.head("snap-1", sha: sha))
    #expect(store.snapshotPlace == .preferences)
    let record = try #require(f.defaults.data(forKey: store.snapKey))
    #expect(record.count < 100_000)
    #expect(try store.heads().map(\.snapshot) == ["snap-1"])
    let out = f.root.appendingPathComponent("out.s2asave")
    try store.download(try store.heads()[0], to: out)
    #expect(try Data(contentsOf: out) == raw)
    // 待定位已转正，偏好里只剩 head 与快照两条
    #expect(f.defaults.data(forKey: store.pendingKey) == nil)
}

@Test func 记录格式往返_含空存档() throws {
    for raw in [Data(), Data("x".utf8), randomBytes(70_000)] {
        let (name, back) = try DeviceSaveStore.unpack(DeviceSaveStore.pack(raw, name: "snap-é"), key: "k")
        #expect(name == "snap-é" && back == raw)
    }
}

@Test func 超900KB落到偏好外的文件_取回一致_换小的回到偏好() throws {
    let f = try Fixture()
    let store = f.store()
    let big = randomBytes(1_000_000)   // 随机数据压不动：压完仍约 1 MB > 900 KB
    let a = try f.file("big.s2asave", big)
    let shaA = try sha256File(a)
    try store.putSnapshot(a, as: "snap-big", sha256: shaA)
    try store.putHead(f.head("snap-big", sha: shaA))
    #expect(store.snapshotPlace == .file)
    #expect(f.defaults.data(forKey: store.snapKey) == nil)
    #expect(FileManager.default.fileExists(atPath: f.spill.appendingPathComponent("0100000000000001_first.snap").path))
    let out = f.root.appendingPathComponent("big-out")
    try store.download(try store.heads()[0], to: out)
    #expect(try Data(contentsOf: out) == big)
    // 换成小存档：回到偏好，旧的落文件删掉
    let small = try f.file("small.s2asave", Data(repeating: 7, count: 10_000))
    let shaB = try sha256File(small)
    try store.putSnapshot(small, as: "snap-small", sha256: shaB)
    try store.putHead(f.head("snap-small", sha: shaB))
    #expect(store.snapshotPlace == .preferences)
    #expect(!FileManager.default.fileExists(atPath: f.spill.appendingPathComponent("0100000000000001_first.snap").path))
}

@Test func 预算按所有存档合计_别的格占满时这一格落文件() throws {
    let f = try Fixture()
    // 别的格先占 850 KB（随机、压不动）
    let other = f.store("0100000000000002/first")
    let o = try f.file("o", randomBytes(850_000)); let shaO = try sha256File(o)
    try other.putSnapshot(o, as: "o1", sha256: shaO); try other.putHead(f.head("o1", sha: shaO))
    #expect(other.snapshotPlace == .preferences)
    // 这一格 100 KB 随机：850 + 100 > 900 → 落文件
    let store = f.store()
    let a = try f.file("a", randomBytes(100_000)); let sha = try sha256File(a)
    try store.putSnapshot(a, as: "a1", sha256: sha); try store.putHead(f.head("a1", sha: sha))
    #expect(store.snapshotPlace == .file)
}

@Test func 损坏数据报错不崩() throws {
    let f = try Fixture()
    let store = f.store()
    let a = try f.file("a", Data(repeating: 1, count: 5000)); let sha = try sha256File(a)
    try store.putSnapshot(a, as: "s1", sha256: sha); try store.putHead(f.head("s1", sha: sha))
    let head = try store.heads()[0]
    let good = try #require(f.defaults.data(forKey: store.snapKey))
    let cases: [Data] = [Data("garbage".utf8), Data(), good.prefix(20), good.prefix(good.count - 3),
                         Data("S2Z1".utf8) + Data(repeating: 0xff, count: 8) + Data([0, 0]) + Data(repeating: 9, count: 40)]
    for (i, bad) in cases.enumerated() {
        f.defaults.set(bad, forKey: store.snapKey)
        #expect(throws: SaveSyncError.corrupt("s1")) { try store.download(head, to: f.root.appendingPathComponent("o\(i)")) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("o\(i)").path))
    }
    // 快照能解开但不是 head 记的那份（sha 不符）
    f.defaults.set(try DeviceSaveStore.pack(Data("other".utf8), name: "s1"), forKey: store.snapKey)
    #expect(throws: SaveSyncError.corrupt("s1")) { try store.download(head, to: f.root.appendingPathComponent("sha")) }
    // head 写坏：当没有
    f.defaults.set(Data("{".utf8), forKey: store.headKey)
    #expect(try store.heads().isEmpty)
}

@Test func 存档目录被清后起局前同步取回() async throws {
    let f = try Fixture()
    let work = f.root.appendingPathComponent("work")
    let store = f.store()
    // 第一回：Caches 里的设备号 A 有存档，同步 → 写进偏好
    let stateA = DeviceSaveState(directory: f.root.appendingPathComponent("caches-1"))
    let a = FakeDevice(stateA.device(), save: ["File1.bin": "v1"], work: work)
    func engine(_ d: FakeDevice, _ state: DeviceSaveState) -> SaveSyncEngine {
        SaveSyncEngine(folder: store, device: d.id, deviceName: "tv", work: work, ports: d.ports,
                       loadBase: { state.loadBase(store.slot) }, storeBase: { state.storeBase(store.slot, $0) })
    }
    #expect(try await engine(a, stateA).sync { _ in nil } == .uploaded)
    #expect(try await engine(a, stateA).sync { _ in nil } == .upToDate)
    // 存档改了：起局前（或切后台）再写进偏好
    a.save = ["File1.bin": "v2"]
    #expect(try await engine(a, stateA).uploadIfAhead() == .uploaded)
    // 系统清掉 Caches：存档、设备号、基线都没了
    let stateB = DeviceSaveState(directory: f.root.appendingPathComponent("caches-2"))
    #expect(stateB.device() != a.id)
    let b = FakeDevice(stateB.device(), save: nil, work: work)
    #expect(try await engine(b, stateB).sync { _ in nil } == .downloaded(from: "tv"))
    #expect(b.save == ["File1.bin": "v2"] && b.restores == 1)
    // 取回后不再动；之后再改照常写进偏好
    #expect(try await engine(b, stateB).sync { _ in nil } == .upToDate)
    b.save = ["File1.bin": "v3"]
    #expect(try await engine(b, stateB).sync { _ in nil } == .uploaded)
    #expect(try store.heads().map(\.device) == [b.id])
}

@Test func 存储里的快照坏了_起局前同步报错且不动本机存档() async throws {
    let f = try Fixture()
    let work = f.root.appendingPathComponent("work")
    let store = f.store()
    let stateA = DeviceSaveState(directory: f.root.appendingPathComponent("c1"))
    let a = FakeDevice(stateA.device(), save: ["f": "v1"], work: work)
    _ = try await SaveSyncEngine(folder: store, device: a.id, deviceName: "tv", work: work, ports: a.ports,
                                 loadBase: { stateA.loadBase(store.slot) }, storeBase: { stateA.storeBase(store.slot, $0) }).sync { _ in nil }
    f.defaults.set(Data("broken".utf8), forKey: store.snapKey)
    let stateB = DeviceSaveState(directory: f.root.appendingPathComponent("c2"))
    let b = FakeDevice(stateB.device(), save: nil, work: work)
    let snapshot = try store.heads()[0].snapshot
    await #expect(throws: SaveSyncError.corrupt(snapshot)) {
        try await SaveSyncEngine(folder: store, device: b.id, deviceName: "tv", work: work, ports: b.ports,
                                 loadBase: { stateB.loadBase(store.slot) }, storeBase: { stateB.storeBase(store.slot, $0) }).sync { _ in nil }
    }
    #expect(b.save == nil && b.restores == 0 && stateB.loadBase(store.slot) == nil)
}
