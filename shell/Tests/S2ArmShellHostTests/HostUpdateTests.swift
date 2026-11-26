import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 程序约定号对不上本宿主的款（宿主 ios/app.m s2a_shell_game_needs_host_update，11-16）：期望按规则手写——
//   资源包就绪、清单写「可玩」、宿主说要在电脑上更新 → 卡片 needsGameUpdate（点开只展开说明，不起局）；
//   宿主说不用 → 照清单「可玩」；资源包不在的款 → 仍是「需要游戏数据」，不被约定号盖掉（先缺数据、再谈更新）；清单本来写别的状态 → 不改

@MainActor @Test func hostUpdateMarksOnlyPlayableGames() {
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"},{"title_id":"0100000000020000","name":"B"},{"title_id":"0100000000030000","name":"C"},{"title_id":"0100000000040000","name":"D","state":"needs_app_update"}]}"#.utf8),
                              baseDirectory: URL(fileURLWithPath: "/"))
    let stale: Set<String> = ["0100000000010000", "0100000000030000", "0100000000040000"]
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, installState: { $0 == "0100000000030000" ? 0 : 1 },
                                    needsHostUpdate: { stale.contains($0) })
    model.refreshGameData()
    let state = Dictionary(uniqueKeysWithValues: model.games.map { ($0.id, $0.game.state) })
    #expect(state["0100000000010000"] == .needsGameUpdate, "就绪、可玩、宿主说约定号对不上 → 需要在电脑上更新")
    #expect(state["0100000000020000"] == .playable, "宿主说对得上 → 照清单可玩")
    #expect(state["0100000000030000"] == .needsGameData, "资源包不在 → 仍是需要游戏数据")
    #expect(state["0100000000040000"] == .needsAppUpdate, "清单本来写 needs_app_update → 不改")
}

// 每款签名状态（宿主 ios/app.m s2a_shell_game_sign_state，0.6.0：签名证书是游戏状态的一部分）：期望按 s2a_shell.h 的码手写——
//   就绪、可玩：1 没证书 / 2 别的团队 / 3 证书已换 / 4 签名格式老 → 「需要签名证书」各带原因（主按钮直接导证书，不先显示可玩）；
//   5 有证书仍被拒 → 需要在电脑上更新；0 → 照清单可玩；资源包不在 → 仍是需要游戏数据（先缺数据）；约定号对不上 → 需要在电脑上更新（先于签名）
@MainActor @Test func signStateMarksOnlyPlayableGames() {
    let ids = (1...8).map { String(format: "01000000000%d0000", $0) }
    let cat = Catalogue.parse(Data(("{\"schema\":1,\"games\":[" + ids.map { "{\"title_id\":\"\($0)\",\"name\":\"x\"}" }.joined(separator: ",") + "]}").utf8),
                              baseDirectory: URL(fileURLWithPath: "/"))
    let code: [String: Int32] = [ids[0]: 1, ids[1]: 2, ids[2]: 3, ids[3]: 4, ids[4]: 5, ids[5]: 0, ids[6]: 1, ids[7]: 1]
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, installState: { $0 == ids[6] ? 0 : 1 },
                                    needsHostUpdate: { $0 == ids[7] }, signState: { code[$0] ?? 0 })
    model.refreshGameData()
    let state = Dictionary(uniqueKeysWithValues: model.games.map { ($0.id, $0.game.state) })
    #expect(state[ids[0]] == .needsCertificate(.missing), "1 → 需要签名证书（没证书）")
    #expect(state[ids[1]] == .needsCertificate(.otherTeam), "2 → 需要签名证书（别的团队）")
    #expect(state[ids[2]] == .needsCertificate(.replaced), "3 → 需要签名证书（已换 / 吊销）")
    #expect(state[ids[3]] == .needsCertificate(.oldSignature), "4 → 需要签名证书（格式老）")
    #expect(state[ids[4]] == .needsGameUpdate, "5 → 需要在电脑上更新")
    #expect(state[ids[5]] == .playable, "0 → 照清单可玩")
    #expect(state[ids[6]] == .needsGameData, "资源包不在 → 仍是需要游戏数据")
    #expect(state[ids[7]] == .needsGameUpdate, "约定号对不上 → 需要在电脑上更新（先于签名）")
}

// 证书导好 → 宿主状态码变 0 → 下一次重判卡片自己回「可以玩」（不用杀 App）
@MainActor @Test func certificateImportRestoresCard() {
    let id = "0100000000010000"
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    var code: Int32 = 1
    let model = S2ArmShellHostModel(catalogue: cat, play: { _ in }, installState: { _ in 1 }, needsHostUpdate: { _ in false }, signState: { _ in code })
    model.refreshGameData()
    #expect(model.games.first { $0.id == id }?.game.state == .needsCertificate(.missing))
    code = 0; model.refreshGameData()
    #expect(model.games.first { $0.id == id }?.game.state == .playable, "导好证书后重判 → 可以玩")
}
