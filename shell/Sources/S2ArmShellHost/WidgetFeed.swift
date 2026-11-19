// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 主屏小组件的共享数据（11-16 维护者：4×2 小组件进 0.5.0）。游戏库（本文件随 S2ArmShellHost 编进主程序）写、
///   小组件扩展（ios/widget，runtime/build.mk 用 swiftc 把本文件一起编进扩展）读——两边同一份代码，格式不会各说各话。
/// 位置：共享组容器里的 widget/games.json + widget/covers/<游戏号>.jpg。
/// 共享组：签名时声明 group.s2arm.widget；各家签名工具会改写成带团队号的 group.s2arm.widget.<团队号>（这个名字全苹果唯一），
///   有的还给每个包另建一个以包名开头的缺省组。所以不写死组名：运行时读本进程签名里的 application-groups，只认这两种写法，
///   主程序与扩展改写后拿到的是同一个组。读不到（签名没带组 / 被侧载工具剥了）= 小组件没有数据，显示「打开 S2Arm」。
public enum WidgetFeed {
    public static let groupBase = "group.s2arm.widget"
    /// 小组件种类名（WidgetCenter 按它刷新）
    public static let kind = "S2ArmGames"
    /// 点封面打开的链接：s2arm://play/<游戏号>（主程序 Info.plist 登记 s2arm，场景代理交给游戏库「开始」同一入口）
    public static let scheme = "s2arm"
    public static func playURL(_ id: String) -> URL? { URL(string: "\(scheme)://play/\(id)") }
    public static func gameID(fromPlayURL url: URL) -> String? {
        guard url.scheme == scheme, url.host == "play" else { return nil }
        let id = url.lastPathComponent
        return id.count == 16 && id.allSatisfy(\.isHexDigit) ? id.uppercased() : nil
    }

    public struct Game: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// 本机累计游玩秒数（运行时写的 playtime.json）；没玩过 0
        public var seconds: Int
        /// 上次玩的时刻（Unix 秒）；没玩过 0
        public var lastPlayed: Double
        /// 封面在 widget/ 下的相对路径；没有封面 nil
        public var cover: String?
        public init(id: String, name: String, seconds: Int, lastPlayed: Double, cover: String?) {
            self.id = id; self.name = name; self.seconds = seconds; self.lastPlayed = lastPlayed; self.cover = cover
        }
    }

    public struct Feed: Codable, Equatable, Sendable {
        public var version = 1
        public var games: [Game]
        public init(games: [Game]) { self.games = games }
    }

    /// 只认 group.s2arm.widget 与 group.s2arm.widget.<团队号>（团队号 10 位字母数字）；别的组（包名开头的缺省组等）不认
    public static func pickGroup(_ groups: [String]) -> String? {
        groups.first { g in
            if g == groupBase { return true }
            guard g.hasPrefix(groupBase + ".") else { return false }
            let team = g.dropFirst(groupBase.count + 1)
            return team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// 本进程签名里生效的共享组（SecTaskCopyValueForEntitlement；iOS 头文件没导出，按符号取，同 ios/iml_probe.m）
    static func entitledGroups() -> [String] {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias Copy = @convention(c) (AnyObject, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<AnyObject>?
        guard let h = dlopen(nil, RTLD_NOW), let c = dlsym(h, "SecTaskCreateFromSelf"), let v = dlsym(h, "SecTaskCopyValueForEntitlement"),
              let task = unsafeBitCast(c, to: Create.self)(nil)?.takeRetainedValue() else { return [] }
        let value = unsafeBitCast(v, to: Copy.self)(task, "com.apple.security.application-groups" as CFString, nil)?.takeRetainedValue()
        return value as? [String] ?? []
    }

    /// 共享组容器下的 widget/ 目录；没有共享组时 nil
    public static func directory(groups: [String]? = nil) -> URL? {
        guard let g = pickGroup(groups ?? entitledGroups()),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else { return nil }
        return root.appendingPathComponent("widget", isDirectory: true)
    }

    public static func read(from dir: URL) -> Feed? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("games.json")) else { return nil }
        return try? JSONDecoder().decode(Feed.self, from: data)
    }

    /// 写一份：内容和已有的一样就不写（返回 false，调用方也就不必叫小组件刷新）。封面按游戏号存 256 px JPEG，只在缺的时候写；
    ///   库里没了的款，封面一并删掉
    @discardableResult
    public static func write(_ feed: Feed, covers: [String: CGImage], to dir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("covers", isDirectory: true), withIntermediateDirectories: true)
        for (id, image) in covers {
            let url = dir.appendingPathComponent("covers/\(id).jpg")
            if !fm.fileExists(atPath: url.path) { saveJPEG(image, to: url) }
        }
        let keep = Set(feed.games.compactMap(\.cover))
        for name in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("covers").path)) ?? [] where !keep.contains("covers/" + name) {
            try? fm.removeItem(at: dir.appendingPathComponent("covers/" + name))
        }
        if read(from: dir) == feed { return false }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(feed) else { return false }
        return (try? data.write(to: dir.appendingPathComponent("games.json"), options: .atomic)) != nil
    }

    static func saveJPEG(_ image: CGImage, to url: URL) {
        let side = 256, w = image.width, h = image.height
        let scale = Double(side) / Double(max(1, min(w, h)))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// 小组件放哪几款（11-16 维护者）：左边 = 最近玩的那款；右边 = 其余玩过的按游玩时长从长到短取 3 款，不够用没玩过的按库里顺序补
    public static func pick(_ games: [Game], side count: Int = 3) -> (main: Game?, side: [Game]) {
        let played = games.filter { $0.seconds > 0 }
        let main = played.max { $0.lastPlayed < $1.lastPlayed } ?? games.first
        let rest = games.filter { $0.id != main?.id }
        let byTime = rest.filter { $0.seconds > 0 }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.lastPlayed > $1.lastPlayed }
        let fill = rest.filter { $0.seconds == 0 }
        return (main, Array((byTime + fill).prefix(count)))
    }
}
