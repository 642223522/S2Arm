import Foundation
import Testing
@testable import SaveSync

// 本地玩家（#623）共享规则：iPhone / iPad 与 Mac 用同一份，同名玩家两端算出同一个用户号（iCloud / 备份恢复过去还是她的存档）。
//   期望由 Python hashlib 独立算出：sha256("S2Arm local player\n" + 小写名字) 前 16 字节，不跑被测实现推
@Test func sameNameGivesTheSameUserOnEveryDevice() throws {
    #expect(LocalPlayers.uid(for: "Hong") == "d7a43a96495d0a594e615dd88587b6bf")
    #expect(LocalPlayers.uid(for: " hong ") == "d7a43a96495d0a594e615dd88587b6bf")
    #expect(LocalPlayers.uid(for: "小红") == "382ddcdad6b762a7590fd9d3fcf74beb")
    let name = "s2a.test.players.core." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
    let store = LocalPlayers(defaults: d, firstDefault: "玩家 1")
    #expect(throws: LocalPlayers.NameError.taken) { try store.add("玩家 1") }   // 第一个玩家没改名时就叫这个
    let p = try store.add("Hong")
    #expect(p.serviceUser == "d7a43a96495d0a594e615dd88587b6bf" && store.all[0].serviceUser == "first")
    #expect(store.all[0].displayName(firstDefault: "玩家 1") == "玩家 1" && p.folder == "SaveData-Hong")
}
