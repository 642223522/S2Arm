// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import CoreGraphics
import Foundation
import ShellUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 游戏库 → 主屏小组件（11-16）：每次重判各款状态（refreshGameData）顺手把「这台设备上显示的游戏、名字、封面、本机游玩时间」
///   写进共享组（WidgetFeed）。内容没变不写、不叫小组件刷新；签名没带共享组（证书模式 / 被侧载工具剥了）直接跳过。
extension S2ArmShellHostModel {
    func exportWidget() {
        guard let dir = WidgetFeed.directory() else { return }
        var covers: [String: CGImage] = [:], list: [WidgetFeed.Game] = []
        for detail in games {
            let tile = detail.game, (seconds, last) = playtimeRaw(tile.id)
            var cover: String?
            if let art = tile.icon ?? tile.banner {
                let name = "\(tile.id)-\(UInt32(truncatingIfNeeded: art.id.hashValue & 0x7fffffff))"   // 换了封面（自定义）文件名跟着换，旧的由 write 清掉
                cover = "covers/\(name).jpg"; covers[name] = art.cgImage
            }
            list.append(WidgetFeed.Game(id: tile.id, name: tile.title, seconds: seconds, lastPlayed: last, cover: cover))
        }
        let feed = WidgetFeed.Feed(games: list)
        if WidgetExportMemo.last == feed { return }   // 库开着时每秒重判一次：和上次一样连磁盘都不碰
        WidgetExportMemo.last = feed
        guard WidgetFeed.write(feed, covers: covers, to: dir) else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetFeed.kind)
        #endif
    }

}

@MainActor enum WidgetExportMemo { static var last: WidgetFeed.Feed? }
