// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S2Arm 主屏小组件（中号 4×2，11-16 维护者：认可的演示版定稿进 0.5.0）。
//   外观 = 掌机样子：左右手柄贴着小组件边缘、中间深灰蓝机身里一块屏幕；屏幕左边大封面 = 最近玩的那款，
//   右边 = 其余游戏里游玩时间最长的三款（WidgetFeed.pick）。点封面打开主程序并直接开这款（s2arm://play/<游戏号>）。
//   数据：游戏库写进共享组的 widget/games.json + covers/（shell/Sources/S2ArmShellHost/WidgetFeed.swift，本文件与它一起编进扩展）；
//   没有共享组 / 没写过 = 显示「打开 S2Arm」。编法：runtime/build.mk 的 ios-widget（swiftc，-application-extension，入口 _NSExtensionMain）。
import SwiftUI
import UIKit
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let main: WidgetFeed.Game?
    let side: [WidgetFeed.Game]
    let dir: URL?
}

struct Provider: TimelineProvider {
    func load(_ date: Date = .now) -> Entry {
        let dir = WidgetFeed.directory()
        let games = dir.flatMap { WidgetFeed.read(from: $0)?.games } ?? []
        let p = WidgetFeed.pick(games)
        return Entry(date: date, main: p.main, side: p.side, dir: dir)
    }
    func placeholder(in context: Context) -> Entry { Entry(date: .now, main: nil, side: [], dir: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(load()) }
    // 游戏库数据变了会主动叫刷新（WidgetCenter）；「昨天 / N 天前」跨日要变，所以第二天零点再取一次
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let next = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(60)
        completion(Timeline(entries: [load()], policy: .after(next)))
    }
}

// MARK: 文案（扩展拿不到主程序的字符串表：六种界面语言写在这里，规则同游戏库 ShellFormat.playtime）

enum Words {
    static let lang: String = {
        let l = Locale.preferredLanguages.first ?? "en"
        if l.hasPrefix("zh-Hant") || l.hasPrefix("zh-TW") || l.hasPrefix("zh-HK") || l.hasPrefix("zh-MO") { return "zh-Hant" }
        for p in ["zh", "ja", "es", "fr"] where l.hasPrefix(p) { return p == "zh" ? "zh-Hans" : p }
        return "en"
    }()
    static func t(_ k: String) -> String { table[k]?[lang] ?? table[k]?["en"] ?? k }
    static let table: [String: [String: String]] = [
        "recent": ["zh-Hans": "最近玩", "zh-Hant": "最近玩", "en": "Recent", "ja": "最近プレイ", "es": "Reciente", "fr": "Récent"],
        "h": ["zh-Hans": "%@ 小时", "zh-Hant": "%@ 小時", "en": "%@ h", "ja": "%@ 時間", "es": "%@ h", "fr": "%@ h"],
        "min": ["zh-Hans": "%@ 分钟", "zh-Hant": "%@ 分鐘", "en": "%@ min", "ja": "%@ 分", "es": "%@ min", "fr": "%@ min"],
        "today": ["zh-Hans": "今天", "zh-Hant": "今天", "en": "today", "ja": "今日", "es": "hoy", "fr": "aujourd’hui"],
        "yesterday": ["zh-Hans": "昨天", "zh-Hant": "昨天", "en": "yesterday", "ja": "昨日", "es": "ayer", "fr": "hier"],
        "days": ["zh-Hans": "%@ 天前", "zh-Hant": "%@ 天前", "en": "%@ days ago", "ja": "%@ 日前", "es": "hace %@ días", "fr": "il y a %@ jours"],
        "notPlayed": ["zh-Hans": "还没玩过", "zh-Hant": "還沒玩過", "en": "Not played yet", "ja": "未プレイ", "es": "Sin jugar", "fr": "Pas encore joué"],
        "empty": ["zh-Hans": "打开 S2Arm，游戏会显示在这里", "zh-Hant": "打開 S2Arm，遊戲會顯示在這裡", "en": "Open S2Arm to see your games here",
                  "ja": "S2Arm を開くとここにゲームが表示されます", "es": "Abre S2Arm para ver aquí tus juegos", "fr": "Ouvrez S2Arm pour voir vos jeux ici"],
        "name": ["zh-Hans": "S2Arm 游戏库", "zh-Hant": "S2Arm 遊戲庫", "en": "S2Arm Library", "ja": "S2Arm ライブラリ", "es": "Biblioteca de S2Arm", "fr": "Bibliothèque S2Arm"],
        "desc": ["zh-Hans": "最近玩的游戏和玩得最多的游戏，点封面直接开", "zh-Hant": "最近玩的遊戲和玩得最多的遊戲，點封面直接開",
                 "en": "Your latest and most-played games. Tap a cover to play.", "ja": "最近遊んだゲームとよく遊ぶゲーム。カバーをタップして起動",
                 "es": "Tus juegos más recientes y más jugados. Toca una portada para jugar.", "fr": "Vos jeux récents et les plus joués. Touchez une couverture pour jouer."],
    ]
    /// 「12 小时 · 昨天」：不满 1 小时按分钟（至少 1）；满 1 小时按 0.1 小时向下取、10 小时起取整；哪天按本机日历日
    static func line(_ g: WidgetFeed.Game, now: Date = .now) -> String {
        guard g.seconds > 0 else { return t("notPlayed") }
        let m = g.seconds / 60
        let dur: String
        if m < 60 { dur = String(format: t("min"), String(max(1, m))) }
        else {
            let tenths = m * 10 / 60
            dur = String(format: t("h"), tenths < 100 ? (tenths % 10 == 0 ? String(tenths / 10) : String(format: "%d.%d", tenths / 10, tenths % 10)) : String(m / 60))
        }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: g.lastPlayed)), to: cal.startOfDay(for: now)).day ?? 0
        let when = days <= 0 ? t("today") : days == 1 ? t("yesterday") : String(format: t("days"), String(days))
        return dur + " · " + when
    }
}

// MARK: 外观（维护者认可的演示版第 4 版）

enum Pad { static let ink = Color(red: 0.13, green: 0.14, blue: 0.24) }

struct PadSide: View {
    let left: Bool
    let h: CGFloat
    var top: Color { left ? Color(red: 0.55, green: 0.48, blue: 0.99) : Color(red: 0.36, green: 0.74, blue: 0.99) }
    var bottom: Color { left ? Color(red: 0.38, green: 0.30, blue: 0.90) : Color(red: 0.16, green: 0.55, blue: 0.93) }
    var body: some View {
        let w = h * 0.26
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .black.opacity(0.28), location: 0), .init(color: .clear, location: 0.35),
                                   .init(color: .white.opacity(0.10), location: 0.6), .init(color: .black.opacity(0.12), location: 1)],
                           startPoint: left ? .leading : .trailing, endPoint: left ? .trailing : .leading)
            RadialGradient(colors: [.white.opacity(0.38), .clear], center: UnitPoint(x: 0.5, y: 0.0), startRadius: 0, endRadius: h * 0.55)
            LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: UnitPoint(x: 0.5, y: 0.7), endPoint: .bottom)
            VStack(spacing: 0) {
                HStack {
                    if left { Spacer() }
                    Image(systemName: left ? "minus" : "plus").font(.system(size: h * 0.05, weight: .heavy)).foregroundStyle(Pad.ink)
                    if !left { Spacer() }
                }
                .padding(.horizontal, w * 0.14).padding(.top, h * 0.07)
                if left {
                    Stick(d: w * 0.52).padding(.top, h * 0.04)
                    Buttons(d: w * 0.2, labels: ["arrowtriangle.up.fill", "arrowtriangle.left.fill", "arrowtriangle.right.fill", "arrowtriangle.down.fill"], symbols: true).padding(.top, h * 0.07)
                } else {
                    Buttons(d: w * 0.2, labels: ["X", "Y", "A", "B"], symbols: false).padding(.top, h * 0.01)
                    Stick(d: w * 0.52).padding(.top, h * 0.07)
                }
                Spacer()
                Group {
                    if left { RoundedRectangle(cornerRadius: 2.5).fill(Pad.ink).frame(width: w * 0.16, height: w * 0.16) }
                    else { Circle().fill(Pad.ink).frame(width: w * 0.2, height: w * 0.2).overlay(Image(systemName: "house.fill").font(.system(size: w * 0.08)).foregroundStyle(.white.opacity(0.5))) }
                }
                .padding(.bottom, h * 0.1)
            }
        }
        .frame(width: w)
        .overlay(alignment: left ? .trailing : .leading) {
            HStack(spacing: 0) {
                if !left { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.6) }
                Rectangle().fill(.black.opacity(0.45)).frame(width: 1)
                if left { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.6) }
            }
        }
    }
}

struct Stick: View {
    let d: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Pad.ink.opacity(0.9)).frame(width: d * 1.1, height: d * 1.1)
            Circle().fill(RadialGradient(colors: [Color(red: 0.30, green: 0.31, blue: 0.40), Pad.ink], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: d * 0.55))
                .frame(width: d * 0.86, height: d * 0.86)
            Circle().stroke(.white.opacity(0.10), lineWidth: 0.8).frame(width: d * 0.62, height: d * 0.62)
        }
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

struct Buttons: View {
    let d: CGFloat
    let labels: [String]
    let symbols: Bool
    var body: some View {
        VStack(spacing: 0) {
            btn(labels[0])
            HStack(spacing: d * 0.75) { btn(labels[1]); btn(labels[2]) }
            btn(labels[3])
        }
    }
    func btn(_ l: String) -> some View {
        ZStack {
            Circle().fill(Pad.ink)
            Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)).padding(d * 0.1)
            if symbols { Image(systemName: l).font(.system(size: d * 0.34)).foregroundStyle(.white.opacity(0.55)) }
            else { Text(l).font(.system(size: d * 0.46, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
        }
        .frame(width: d, height: d).shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.8)
    }
}

struct CoverImage: View {
    let game: WidgetFeed.Game
    let dir: URL?
    var body: some View {
        if let c = game.cover, let d = dir, let img = UIImage(contentsOfFile: d.appendingPathComponent(c).path) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.80), Color(red: 0.12, green: 0.45, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "gamecontroller.fill").foregroundStyle(.white.opacity(0.5)))
        }
    }
}

struct ScreenView: View {
    let entry: Entry
    var body: some View {
        Group {
            if let main = entry.main {
                HStack(spacing: 5) {
                    Link(destination: WidgetFeed.playURL(main.id)!) {
                        ZStack(alignment: .bottomLeading) {
                            CoverImage(game: main, dir: entry.dir)
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 1) {
                                if main.seconds > 0 {
                                    Text(Words.t("recent")).font(.system(size: 8.5, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                                Spacer()
                                Text(main.name).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(Words.line(main, now: entry.date)).font(.system(size: 9)).opacity(0.85).lineLimit(1)
                            }
                            .foregroundStyle(.white).padding(6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .frame(maxWidth: .infinity)
                    if !entry.side.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entry.side, id: \.id) { g in
                                Link(destination: WidgetFeed.playURL(g.id)!) {
                                    HStack(spacing: 6) {
                                        CoverImage(game: g, dir: entry.dir).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(g.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                            Text(Words.line(g, now: entry.date)).font(.system(size: 7.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                                                .lineLimit(1).minimumScaleFactor(0.8)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxHeight: .infinity)
                                }
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        .layoutPriority(1)
                    }
                }
            } else {
                Text(Words.t("empty")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(4)
        .background(Color(red: 0.04, green: 0.045, blue: 0.06), in: RoundedRectangle(cornerRadius: 5))
        .padding(.vertical, 7).padding(.horizontal, 6)
        .background(
            ZStack {
                LinearGradient(colors: [Color(red: 0.40, green: 0.43, blue: 0.52), Color(red: 0.27, green: 0.29, blue: 0.37)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            }
        )
    }
}

struct WidgetView: View {
    let entry: Entry
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) { PadSide(left: true, h: g.size.height); ScreenView(entry: entry); PadSide(left: false, h: g.size.height) }
        }
    }
}

struct S2ArmGamesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFeed.kind, provider: Provider()) { entry in
            WidgetView(entry: entry).containerBackground(for: .widget) { Color(red: 0.30, green: 0.32, blue: 0.40) }
        }
        .configurationDisplayName(Words.t("name"))
        .description(Words.t("desc"))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main struct S2ArmWidgetBundle: WidgetBundle {
    var body: some Widget { S2ArmGamesWidget() }
}
