import Foundation
import Testing
import ShellUI
@testable import S2ArmShellHost

// 丢了「提高内存上限」权限的游戏库提示（宿主 ios/iml_probe.m s2a_shell_iml_notice，确定丢了才给标题 / 正文）。期望按规则手写：
//   带权限 / 读不到（宿主给 nil）→ 不出；丢了 → 出、文字就是宿主给的；玩家关了 → 只管这次打开；下次打开仍丢 → 又出（11-16 维护者：别永久静默）；
//   「了解详情」打开教程页

@MainActor @Test func imlNoticeShowsOnEveryOpenUntilFixed() throws {
    let name = "s2a.test.iml." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: d)
    let cat = Catalogue.parse(Data(#"{"schema":1,"games":[{"title_id":"0100000000010000","name":"A"}]}"#.utf8), baseDirectory: URL(fileURLWithPath: "/"))
    let lost = #"{"title":"T","body":"B"}"#
    func model(_ json: String?) -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: cat, play: { _ in }, stores: stores, installState: { _ in 1 }, imlNotice: { json })
    }
    #expect(model(nil).imlNotice == nil, "带权限 / 读不到：宿主不给，不出")
    let m = model(lost)
    #expect(m.imlNotice == .init(title: "T", body: "B"), "丢了：出，文字是宿主给的")
    #expect(!m.imlGuideOpen)
    m.openIMLGuide()
    #expect(m.imlGuideOpen, "「了解详情」打开教程页")
    m.closeIMLNotice()
    #expect(m.imlNotice == nil, "关了：这次打开不再出")
    #expect(model(lost).imlNotice != nil, "下次打开仍丢：又出，不永久静默")
    #expect(S2ArmShellHostModel.imlNotice(json: #"{"title":"","body":"B"}"#) == nil, "没有标题不出")
    #expect(S2ArmShellHostModel.imlNotice(json: "not json") == nil)
}

@MainActor @Test func imlGuideListsEveryInstallWay() {
    // 了解详情页：启动器 / 自己的开发者证书（11-17 补）/ AltStore Classic / SideStore / Sideloadly / GetMoreRam 都写到；查不到能保留的写「暂不支持」
    let ways = IMLGuideView.ways
    #expect(ways.map(\.id) == ["launcher", "cert", "altstore", "sidestore", "sideloadly", "getmoreram"])
    #expect(ways.first { $0.id == "sideloadly" }?.verdict == .unsupported)
    #expect(ways.first { $0.id == "sidestore" }?.verdict == .drops)
}
