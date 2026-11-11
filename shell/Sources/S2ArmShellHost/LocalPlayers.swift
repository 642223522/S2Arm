import Foundation
import SaveSync
import ShellUI

/// 本地玩家（#623）：玩家表与规则在共享包 SaveSync（launchers/shared/SaveSync/Sources/SaveSync/LocalPlayers.swift，Mac 启动器同一份）；
///   这里只补游戏库界面的说法：第一个玩家没改过名时叫「玩家 1」（按 App 语言）
extension LocalPlayer {
    public var displayName: String { displayName(firstDefault: shellText("Player 1")) }
}

extension LocalPlayers {
    /// 游戏库用的玩家表：存在 App 偏好（宿主 ios/settings.m 读同一处）
    public init(shellDefaults defaults: UserDefaults) { self.init(defaults: defaults, firstDefault: shellText("Player 1")) }
}
