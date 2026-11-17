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
