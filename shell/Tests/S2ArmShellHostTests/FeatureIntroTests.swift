// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPhone 新功能介绍（0.6.0 起）：宿主读 App 包里 Feature/feature.json。期望直接取自写进去的文件：中文界面取中文、其余取英文；
//   换字的栏目标题照给；文字缺一的页不要；一页不剩 / 文件没有 → nil（不弹、设置里没有那一行）
import Foundation
import Testing
@testable import ShellUI
@testable import S2ArmShellHost

@MainActor @Test func featureIntroReadsPagesInThePlayersLanguage() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func t(_ zh: String, _ en: String) -> [String: String] { ["zh-Hans": zh, "en": en] }
    let full: [String: Any] = ["image": t("a.jpg", "a.jpg"), "kicker": t("快照", "Snapshots"), "title": t("存下这一刻", "Save this moment"),
                               "what": t("是", "What"), "how": t("用", "How"), "where": t("知道", "Know"), "labels": ["where": t("要知道", "Good to know")]]
    var broken = full; broken["title"] = ["zh-Hans": "只有中文"]
    let json: [String: Any] = ["id": "v0.6.0", "badge": t("0.6.0 新功能", "New in 0.6.0"), "pages": [full, broken]]
    try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("feature.json"))
    let zh = try #require(S2ArmShellHostModel.loadFeatureIntro(dir, language: "zh-Hans-CN"))
    #expect(zh.id == "v0.6.0" && zh.badge == "0.6.0 新功能")
    #expect(zh.pages.count == 2)                                   // 中文界面：两页中文都齐
    #expect(zh.pages[0].title == "存下这一刻" && zh.pages[0].labels["where"] == "要知道")
    #expect(zh.pages[0].picture == nil)                              // 图不在：照样给文字
    let en = try #require(S2ArmShellHostModel.loadFeatureIntro(dir, language: "fr-FR"))
    #expect(en.pages.count == 1 && en.pages[0].title == "Save this moment")   // 非中文取英文；缺英文的那页不要
    #expect(S2ArmShellHostModel.loadFeatureIntro(dir.appendingPathComponent("none")) == nil)
}
