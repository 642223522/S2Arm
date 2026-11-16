import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 游戏账本（Documents/.s2a-games.json，双端常驻方案 11-16）：期望按规则手写。
//   旧删除名单并进来（removed）后旧文件删掉；有资源的款记 present；App 里删 → removed、时刻是删的那一刻；资源回来 → present；
//   program（电脑侧给的程序摘要）手机原样保留；账本只在正式游戏根时放 Documents 下
@MainActor @Test func gameLedgerRecordsPresentAndRemoved() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("s2a-ledger-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let (a, b, c) = ("0100000000010000", "0100000000020000", "0100000000030000")
    try fm.createDirectory(at: root.appendingPathComponent("\(a)/资源包"), withIntermediateDirectories: true)
    // A 的程序副本：main 0x40 起 32 字节 = 01 02 … 20 → 构建号 0102…20（大写十六进制）
    try fm.createDirectory(at: root.appendingPathComponent("\(a)/.s2a-program"), withIntermediateDirectories: true)
    try Data(Array(repeating: 0, count: 0x40) + (1...32).map { UInt8($0) } + [0xFF]).write(to: root.appendingPathComponent("\(a)/.s2a-program/main"))
    let buildA = (1...32).map { String(format: "%02X", $0) }.joined()
    try Data("\(c)\nnot-hex\n".utf8).write(to: root.appendingPathComponent(".s2a-removed.txt"))
    try Data(#"{"version":1,"games":{"0100000000010000":{"state":"present","at":5,"program":"P-A"}}}"#.utf8).write(to: root.appendingPathComponent(".s2a-games.json"))
    var clock = Date(timeIntervalSince1970: 1000)
    let data = Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"},{"title_id":"0100000000030000","name":"C"}]}"#.utf8)
    let state: (String) -> Int32 = { fm.fileExists(atPath: root.appendingPathComponent("\($0)/资源包").path) ? 1 : 0 }
    func open() -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: Catalogue.parse(data, baseDirectory: URL(fileURLWithPath: "/")), play: { _ in }, installState: state, now: { clock }, gamesRoot: root)
    }
    struct File: Decodable { let version: Int; let games: [String: S2ArmShellHostModel.LedgerEntry] }
    func read() throws -> File { try JSONDecoder().decode(File.self, from: Data(contentsOf: root.appendingPathComponent(".s2a-games.json"))) }

    let model = open()
    var f = try read()
    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".s2a-removed.txt").path), "旧名单并入后删掉")
    #expect(f.version == 1 && f.games[c] == .init(state: "removed", at: 1000, program: ""), "旧名单的款记 removed、没副本 program 空串；不是游戏号的行不收")
    #expect(f.games[a] == .init(state: "present", at: 5, program: buildA), "状态没变：时刻不动；program 按副本现读的构建号")
    #expect(f.games[b] == nil, "没资源、没删过：不记")
    #expect(model.games.map(\.id) == [a, b], "C 删过且没资源：不显示")

    clock = Date(timeIntervalSince1970: 2000)
    model.deleteGame(a, saves: false)
    f = try read()
    #expect(f.games[a] == .init(state: "removed", at: 2000, program: buildA), "删了：removed、时刻是删的那一刻、program 保留")
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("\(a)/.s2a-program").path), "程序副本随这款目录一起删（存档没勾也删）")

    clock = Date(timeIntervalSince1970: 3000)
    try fm.createDirectory(at: root.appendingPathComponent("\(c)/资源包"), withIntermediateDirectories: true)
    model.refreshGameData()
    f = try read()
    #expect(f.games[c] == .init(state: "present", at: 3000, program: ""), "电脑重装、资源回来：改回 present；没副本 program 空串")
    #expect(model.games.map(\.id).contains(c))

    let home = URL(fileURLWithPath: "/var/mobile/X")
    #expect(S2ArmShellHostModel.ledgerURL(for: home.appendingPathComponent("Documents/games"), home: home).path == "/var/mobile/X/Documents/.s2a-games.json")
    #expect(S2ArmShellHostModel.ledgerURL(for: root, home: home) == root.appendingPathComponent(".s2a-games.json"))
}
