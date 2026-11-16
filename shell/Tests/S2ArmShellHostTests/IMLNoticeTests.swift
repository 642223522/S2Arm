import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 丢了「提高内存上限」权限的游戏库提示（宿主 ios/iml_probe.m s2a_shell_iml_notice，确定丢了才给标题 / 正文）。期望按规则手写：
//   带权限 / 读不到（宿主给 nil）→ 不出；丢了 → 出、文字就是宿主给的；玩家关了 → 同一安装（App 包路径）再开游戏库不出；换了安装（重装 / 更新后路径变）→ 又出

@MainActor @Test func imlNoticeShowsWhenLostAndStaysClosedForThisInstall() throws {
    let name = "s2a.test.iml." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: d)
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    let lost = #"{"title":"T","body":"B"}"#
    func model(_ json: String?, install: String) -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 }, imlNotice: { json }, installID: install)
    }
    #expect(model(nil, install: "/A").imlNotice == nil, "带权限 / 读不到：宿主不给，不出")
    let m = model(lost, install: "/A")
    #expect(m.imlNotice == .init(title: "T", body: "B"), "丢了：出，文字是宿主给的")
    m.closeIMLNotice()
    #expect(m.imlNotice == nil && d.string(forKey: S2ArmShellHostModel.imlClosedKey) == "/A")
    #expect(model(lost, install: "/A").imlNotice == nil, "同一安装关过：不再出")
    #expect(model(lost, install: "/B").imlNotice != nil, "换了安装仍丢：又出")
    #expect(S2ArmShellHostModel.imlNotice(json: #"{"title":"","body":"B"}"#, closed: nil, install: "/A") == nil, "没有标题不出")
    #expect(S2ArmShellHostModel.imlNotice(json: "not json", closed: nil, install: "/A") == nil)
}
