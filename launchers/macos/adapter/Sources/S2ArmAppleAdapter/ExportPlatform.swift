import Foundation

/// 出包平台（11-02 维护者：iPhone / iPad（同一个 iOS 包）、macOS、安卓、鸿蒙，按这个顺序列；同旧启动器 BuildPlatform 的 id）。
/// 安卓、鸿蒙留位置、置灰「即将上线，敬请期待」：开放某个平台只改 released 与 target。
public enum ExportPlatform: String, CaseIterable, Identifiable {
    case ios, mac, android, ohos

    public var id: String { rawValue }

    /// 对玩家开放的平台。
    public var released: Bool { target != nil }

    /// 出这个平台交哪种 build（未开放的没有）。
    public var target: EngineTarget? {
        switch self {
        case .ios: return .iPhone
        case .mac: return .mac
        case .android, .ohos: return nil
        }
    }

    /// 记住的勾选（旧启动器 preferences.exportTargets 的语义：平台 id 列表）里玩家能出的，按页面顺序；未开放的永远不算。
    /// 一个平台一个作业，就按这个顺序排队。
    public static func picked(_ stored: [String]) -> [ExportPlatform] {
        allCases.filter { $0.released && stored.contains($0.rawValue) }
    }

    /// 勾上 / 取消一个平台后的列表（未开放的不动）。
    public static func toggled(_ stored: [String], _ platform: ExportPlatform) -> [String] {
        guard platform.released else { return stored }
        return stored.contains(platform.rawValue) ? stored.filter { $0 != platform.rawValue } : stored + [platform.rawValue]
    }
}
