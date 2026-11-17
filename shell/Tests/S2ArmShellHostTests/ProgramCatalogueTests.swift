import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 0.6.0 通用壳：「推到 iPhone」只推这一款、不重装 App，游戏库要把各款程序包清单 <根>/<号>/program/catalogue.json 并进来（Catalogue.merge）。
// 期望按规则手写：
//   App 包清单有 A；程序包有 B（App 包没有）→ 列出 A、B；程序包也有 A（改了名）→ A 以程序包那条为准（名字是新的），只出现一次；
//   B 的图标按版本目录 program/<dir>/ 取；dir 不合规的 C、清单不是这一款的 D、目录名不是游戏号的 → 都不列，记问题
@Test func programCataloguesMergeIntoLibrary() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("s2a-progcat-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let app = tmp.appendingPathComponent("S2Arm.app"), root = tmp.appendingPathComponent("games")
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    try Data(#"{"schema":1,"shell_id":"x","games":[{"title_id":"0100000000010000","name":"A 旧名"}]}"#.utf8).write(to: app.appendingPathComponent("s2a_catalogue.json"))
    func program(_ id: String, _ json: String, dir: String? = nil, icon: Bool = false) throws {
        let p = root.appendingPathComponent(id).appendingPathComponent("program")
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: p.appendingPathComponent("catalogue.json"))
        if let dir, icon {
            let g = p.appendingPathComponent(dir).appendingPathComponent("Games").appendingPathComponent(id)
            try fm.createDirectory(at: g, withIntermediateDirectories: true)
            try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!.write(to: g.appendingPathComponent("icon.jpg"))   // 1×1 PNG（Artwork 要能解码的图）
        }
    }
    try program("0100000000020000", #"{"title_id":"0100000000020000","name":"B","display_version":"1.0.1","icon":"Games/0100000000020000/icon.jpg","dir":"v-aaaaaaaaaaaaaaaa-pc"}"#, dir: "v-aaaaaaaaaaaaaaaa-pc", icon: true)
    try program("0100000000010000", #"{"title_id":"0100000000010000","name":"A 新名","dir":"v-bbbbbbbbbbbbbbbb-pc"}"#)
    try program("0100000000030000", #"{"title_id":"0100000000030000","name":"C","dir":"../x"}"#)
    try program("0100000000040000", #"{"title_id":"0100000000099999","name":"D"}"#)
    try fm.createDirectory(at: root.appendingPathComponent("not-a-title"), withIntermediateDirectories: true)
    let c = Catalogue.load(path: app.appendingPathComponent("s2a_catalogue.json").path, programRoot: root)
    let ids = c.tiles.map(\.id)
    #expect(ids == ["0100000000010000", "0100000000020000"], "只列 A、B（实际 \(ids)）")
    #expect(c.tiles.first { $0.id == "0100000000010000" }?.title == "A 新名", "同号以程序包那条为准")
    let b = c.tiles.first { $0.id == "0100000000020000" }
    #expect(b?.title == "B" && b?.subtitle == "1.0.1", "程序包里才有的款：名字、版本取程序包清单")
    #expect(b?.icon != nil, "图标按 program/<dir>/ 取到")
    #expect(c.problems.contains { $0.contains("0100000000030000") && $0.contains("dir") }, "dir 不合规的款记问题")
    #expect(c.problems.contains { $0.contains("0100000000040000") }, "清单不是这一款的记问题")
}

// 只装壳的容器：App 包清单 games 为空、也没有程序包 → 空游戏库，不报「清单读不了」
@Test func shellOnlyCatalogueIsEmptyLibrary() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("s2a-shellonly-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let p = tmp.appendingPathComponent("s2a_catalogue.json")
    try Data(#"{"schema":1,"shell_id":"x","games":[]}"#.utf8).write(to: p)
    let c = Catalogue.load(path: p.path, programRoot: tmp.appendingPathComponent("none"))
    #expect(c.tiles.isEmpty && c.problems.isEmpty, "空清单 → 空游戏库、没有问题（实际 \(c.problems)）")
}
