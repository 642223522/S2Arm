import Foundation
import ShellUI

/// 游戏目录清单（catalogue JSON）：S2Arm 出包 / 组装期写、库界面读。字段名取上游 `game.manifest.json`（schema 1）的必要子集，
/// 同名同义，未来接对方 manifest 不改键；不认识的键忽略。
///
/// ```json
/// { "schema": 1,
///   "games": [ { "title_id": "0100ABCDEF012345", "name": "游戏名", "display_version": "1.0.0",
///                "banner": "covers/x.jpg", "icon": "icons/x.png",
///                "state": "playable" | "needs_game_data" | "needs_app_update" | "broken",
///                "reason": "一行原因", "detail": "给玩家的一句话" } ] }
/// ```
/// banner / icon 是相对清单所在目录的路径（也可绝对路径），读不到就不显示图（界面画占位）。
public struct CatalogueEntry: Decodable, Equatable, Sendable {
    public var titleID: String
    public var name: String
    public var displayVersion: String?
    public var banner: String?
    public var icon: String?
    public var state: String?
    public var reason: String?
    public var detail: String?
    /// 程序包清单（program/catalogue.json，0.6.0 写入规则）里指向这一版的版本目录 v-…；App 包清单没有这个字段
    public var dir: String?

    enum CodingKeys: String, CodingKey {
        case name, banner, icon, state, reason, detail, dir
        case titleID = "title_id", displayVersion = "display_version"
    }
}

public struct CatalogueFile: Decodable, Equatable, Sendable {
    public var schema: Int
    public var games: [CatalogueEntry]
    public static let supportedSchema = 1
}

/// 读清单的结果：界面用的条目 + 读的过程中发现的问题（只进日志，不弹窗）。
public struct Catalogue: Equatable, Sendable {
    public var tiles: [GameTile]
    public var problems: [String]
    /// 游戏号 → 封面（banner）文件：虚拟手柄布局编辑页拿它当范例底图（Artwork 的像素在上游模块里不公开）
    public var bannerURLs: [String: URL] = [:]

    /// 从文件读；文件不在 / 坏了 → 空列表 + 一条问题。
    public static func load(path: String, programRoot: URL? = Catalogue.defaultProgramRoot()) -> Catalogue {
        let url = URL(fileURLWithPath: path)
        var c: Catalogue
        if let data = try? Data(contentsOf: url) { c = parse(data, baseDirectory: url.deletingLastPathComponent()) }
        else { c = Catalogue(tiles: [], problems: ["清单读不了：\(path)"]) }
        if let programRoot { c.merge(programs: programRoot) }
        return c
    }

    /// 各款程序包 / 资源包所在的根（同 runtime/include/s2a_docs.h s2a_pack_base_rel：备用位置 Library/S2Arm/games 在就取它，否则 Library/Application Support/S2Arm/games）
    public static func defaultProgramRoot() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let alt = home.appendingPathComponent("Library/S2Arm/games"), main = home.appendingPathComponent("Library/Application Support/S2Arm/games")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: alt.path, isDirectory: &isDir) && isDir.boolValue ? alt : main
    }

    /// 0.6.0 通用壳：「推到 iPhone」只推这一款、不重装 App，新推进来的款在 App 包清单里没有条目——按每款程序包清单 <根>/<号>/program/catalogue.json
    /// 列进来（单个对象，字段同 App 包清单条目，另有 dir）。图 / 补丁表都相对版本目录 program/<dir>/（没写 dir = program/）。
    /// 同一个号 App 包清单里也有：以程序包这条为准（换上的是这一版）。游戏号不合规的目录、清单读不了 / 不是这一款的都跳过并记问题
    mutating func merge(programs root: URL) {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for id in ids.sorted() where isTitleID(id) {
            let prog = root.appendingPathComponent(id).appendingPathComponent("program")
            guard let data = try? Data(contentsOf: prog.appendingPathComponent("catalogue.json")) else { continue }
            guard let e = try? JSONDecoder().decode(CatalogueEntry.self, from: data), e.titleID == id else { problems.append("程序包清单 \(id) 读不了或不是这一款，跳过"); continue }
            if let d = e.dir, !d.isEmpty, !(d.hasPrefix("v-") && !d.contains("/") && !d.contains("..")) { problems.append("程序包清单 \(id) 的 dir「\(d)」不合规，跳过"); continue }
            let base = (e.dir ?? "").isEmpty ? prog : prog.appendingPathComponent(e.dir!)
            let t = Catalogue.tile(e, base: base, sgradeDirs: [base.appendingPathComponent("Games").appendingPathComponent(id)])
            if let i = tiles.firstIndex(where: { $0.id == id }) { tiles[i] = t } else { tiles.append(t) }
            if let b = e.banner, !b.isEmpty { bannerURLs[id] = b.hasPrefix("/") ? URL(fileURLWithPath: b) : base.appendingPathComponent(b) }
        }
    }

    static func tile(_ e: CatalogueEntry, base: URL, sgradeDirs: [URL]) -> GameTile {
        var state = gameState(e)
        if !isTitleID(e.titleID) { state = .broken(reason: "", detail: "", technical: shellText("title_id \"\(e.titleID)\" is not 16 uppercase hexadecimal digits")) }
        return GameTile(id: e.titleID, title: e.name, subtitle: e.displayVersion ?? "",
                        banner: artwork(e.banner, id: e.titleID + ".banner", base: base),
                        icon: artwork(e.icon, id: e.titleID + ".icon", base: base),
                        state: state, sgrade: sgradeIn(sgradeDirs))
    }

    /// 纯解析：同一份字节与目录总得同一结果（单测直接测它）。
    public static func parse(_ data: Data, baseDirectory: URL) -> Catalogue {
        let file: CatalogueFile
        do { file = try JSONDecoder().decode(CatalogueFile.self, from: data) }
        catch { return Catalogue(tiles: [], problems: ["清单 JSON 坏了：\(error)"]) }
        guard file.schema == CatalogueFile.supportedSchema else {
            return Catalogue(tiles: [], problems: ["清单 schema \(file.schema) 不认（只认 \(CatalogueFile.supportedSchema)）"])
        }
        var seen = Set<String>()
        var tiles: [GameTile] = []
        var problems: [String] = []
        var banners: [String: URL] = [:]
        for e in file.games {
            // 同一 title_id 只留第一条：界面以 id 区分条目，重复会乱焦点
            guard seen.insert(e.titleID).inserted else { problems.append("重复的 title_id \(e.titleID)，后一条丢弃"); continue }
            var state = gameState(e)
            if !isTitleID(e.titleID) {
                state = .broken(reason: "", detail: "", technical: shellText("title_id \"\(e.titleID)\" is not 16 uppercase hexadecimal digits"))
                problems.append("title_id \"\(e.titleID)\" 不合规，按不可用显示")
            }
            if let b = e.banner, !b.isEmpty { banners[e.titleID] = b.hasPrefix("/") ? URL(fileURLWithPath: b) : baseDirectory.appendingPathComponent(b) }
            tiles.append(GameTile(id: e.titleID, title: e.name, subtitle: e.displayVersion ?? "",
                                  banner: artwork(e.banner, id: e.titleID + ".banner", base: baseDirectory),
                                  icon: artwork(e.icon, id: e.titleID + ".icon", base: baseDirectory),
                                  state: state, sgrade: sgradeBuilt(e.titleID, base: baseDirectory, single: file.games.count == 1)))
        }
        var c = Catalogue(tiles: tiles, problems: problems); c.bannerURLs = banners
        return c
    }

    /// 封面金色 S（v0.4.0）：这款打进了 S 级优化——补丁表（多款容器 Games/<游戏号>/cpatch.tsv；单款 App 根 cpatch.tsv）有表头以外的条目，
    /// 或带着随包金手指原文 cheat-src.*（多数金手指只改内存、不进补丁表；11-14 与 Mac pack/jobs/library.py sgrade_badge 同口径）
    static func sgradeBuilt(_ id: String, base: URL, single: Bool) -> Bool {
        sgradeIn([base.appendingPathComponent("Games").appendingPathComponent(id)] + (single ? [base] : []))
    }
    static func sgradeIn(_ dirs: [URL]) -> Bool {
        for dir in dirs {
            if let text = try? String(contentsOf: dir.appendingPathComponent("cpatch.tsv"), encoding: .utf8),
               text.split(whereSeparator: \.isNewline).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 { return true }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path), names.contains(where: { $0.hasPrefix("cheat-src.") }) { return true }
        }
        return false
    }

    static func gameState(_ e: CatalogueEntry) -> GameState {
        switch e.state ?? "playable" {
        case "playable": .playable
        case "needs_game_data": .needsGameData
        case "needs_app_update": .needsAppUpdate
        case "broken": .broken(reason: e.reason ?? "", detail: e.detail ?? "")
        case let other: .broken(reason: "", detail: "", technical: shellText("Unknown state \"\(other)\""))
        }
    }

    static func artwork(_ path: String?, id: String, base: URL) -> Artwork? {
        guard let path, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Artwork(id: id, data: data)
    }
}

/// 与上游 GameManifest 同口径：16 位数字或大写 A–F。
func isTitleID(_ text: String) -> Bool {
    text.count == 16 && text.allSatisfy { $0.isNumber || ("A"..."F").contains($0) }
}
