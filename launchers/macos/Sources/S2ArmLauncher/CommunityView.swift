// 社区资源（10-27 维护者 01:4x 改定；后端 pack/jobs/community.py）：补丁一律打进包，宽屏 / 60 帧是宿主运行时开关——缺省勾选、可取消，
//   下次启动生效（Mac 启动器转成 S2A_WIDESCREEN=0 / S2A_FPS60=0，iPhone 在 App 设置页同名开关）；版本对不上的补丁编译时由直连线跨版本定位，不判不可用；
//   画面类（other-gfx）逐项开关、同互斥组单选；着色器缓存命中就自动并入，导入入口留给玩家导自己的缓存（读取器接好前不可用）。
import AppKit
import SwiftUI

struct CommunityTable: Decodable, Equatable {
    let verified: Bool; let sources: [String]; let relocate: Bool; let available: Bool; let enabled: Bool
}
struct CommunityGfx: Decodable, Identifiable, Equatable {
    let id: String; let label: String; let exclusive: String; let source: String
    let state: String; let relocate: Bool; let enabled: Bool
}
struct CommunityState: Decodable, Equatable {
    let gameId: String; let version: String
    let widescreen: CommunityTable; let fps60: CommunityTable; let graphics: [CommunityGfx]
}

extension Store {
    func loadCommunity(_ game: Game, done: @escaping (CommunityState?) -> Void) {
        worker("community", extra:["gameId":game.id], visible:false) { done(Self.communityState($0)) }
    }
    /// 存开关（只改宿主设置，不重出包）：change 里带 widescreen / fps60（Bool）或 graphics（[编号: Bool]）
    func setCommunity(_ game: Game, _ change: [String:Any], done: @escaping (CommunityState?) -> Void) {
        worker("communitySave", extra:change.merging(["gameId":game.id]) { a, _ in a }, visible:false) { done(Self.communityState($0)) }
    }
    static func communityState(_ r: [String:Any]) -> CommunityState? {
        guard r["widescreen"] != nil, let data = try? JSONSerialization.data(withJSONObject:r) else { return nil }
        return try? JSONDecoder().decode(CommunityState.self, from:data)
    }
}

struct CommunitySection: View {
    @EnvironmentObject var store: Store
    let game: Game
    var showsHeading: Bool
    @State private var state: CommunityState?
    @State private var busy = false
    @State private var showInfo = false
    @State private var caches: [(name: String, bytes: Int64)] = []
    @State private var cacheNote: String?
    private let fixed: Bool   // 单测 / 截图给定数据：不去后端读
    init(game: Game, state: CommunityState? = nil, showsHeading: Bool = true) { self.game = game; self.showsHeading = showsHeading; _state = State(initialValue:state); fixed = state != nil }

    var body: some View {
        VStack(alignment:.leading, spacing:12) {
            HStack {
                if showsHeading {Label(L("社区资源"), systemImage:"puzzlepiece.extension").font(.headline)}
                Spacer()
                Button { showInfo = true } label:{Label(L("来源与说明"),systemImage:"info.circle").font(.caption)}.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("社区资源说明"))
                    .popover(isPresented:$showInfo, arrowEdge:.trailing) { info }
            }
            if let s = state {
                tableRow(L("宽屏"), s.widescreen, key:"widescreen", none:L("这款没有宽屏表"))
                tableRow(L("60 帧"), s.fps60, key:"fps60", none:L("这款没有 60 帧表"))
                if s.widescreen.available || s.fps60.available {
                    Label(L("宽屏和 60 帧会提高系统负载和耗电，换取更好的游玩体验，低配设备请谨慎选择。"), systemImage:"bolt.badge.clock")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("改完下次启动生效，不用重新编译。")).font(.caption2).foregroundStyle(.tertiary)
                }
                graphics(s.graphics)
            } else {
                ProgressView().controlSize(.small)
            }
            Divider()
            VStack(alignment:.leading, spacing:4) {
                Text(L("着色器缓存")).font(.subheadline.weight(.semibold))
                ForEach(caches, id:\.name) { c in
                    Label(c.name + " · " + ByteCountFormatter.string(fromByteCount:c.bytes, countStyle:.file), systemImage:"doc.zipper").font(.caption).foregroundStyle(.secondary)
                }
                Button(action:importCaches) { Label(L("导入着色器缓存…"), systemImage:"square.and.arrow.down").frame(maxWidth:.infinity) }
                    .buttonStyle(.bordered)
                HStack {
                    Text(L("缓存需匹配游戏版本，下次准备时自动使用。")).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if !caches.isEmpty { Button(L("清除")) { clearCaches() }.buttonStyle(.borderless).font(.caption) }
                }
                if let cacheNote { Text(cacheNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { if !fixed { reload() } }.onChange(of:game.id) { _, _ in cacheNote = nil; if !fixed { state = nil; reload() } }
    }

    private func reload() {
        caches = ShaderCacheImport.list(root:store.privateRoot, gameId:game.id)
        store.loadCommunity(game) { state = $0 }
    }
    /// 文件面板选 yuzu 系 *.bin 或 Ryujinx 缓存目录（可多选）→ 拷进数据目录的着色器缓存 / <程序号>；只读玩家选中的那几项
    private func importCaches() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = L("选 yuzu / Eden / suyu / sudachi 的 vulkan.bin、opengl.bin，或 Ryujinx 的着色器缓存目录（含 shared.toc / guest.toc）")
        guard panel.runModal() == .OK else { return }
        let r = ShaderCacheImport.importItems(panel.urls, root:store.privateRoot, gameId:game.id)
        caches = ShaderCacheImport.list(root:store.privateRoot, gameId:game.id)
        cacheNote = ([r.imported.isEmpty ? nil : L("已导入：") + r.imported.joined(separator:"、") + L("，下次编译时并入")] + r.skipped.map { Optional(L("没导入 ") + $0) })
            .compactMap { $0 }.joined(separator:"\n")
    }
    // 清除失败如实报，列表按盘上真实剩余刷新（审计 18:00 P2-35：原先直接清成空）
    private func clearCaches() {
        do { try ShaderCacheImport.clear(root:store.privateRoot, gameId:game.id); cacheNote = nil }
        catch { cacheNote = L("没清干净：") + error.localizedDescription }
        caches = ShaderCacheImport.list(root:store.privateRoot, gameId:game.id)
    }
    private func save(_ change: [String:Any]) {
        busy = true
        store.setCommunity(game, change) { s in busy = false; if let s { state = s } }
    }

    @ViewBuilder private func tableRow(_ title: String, _ t: CommunityTable, key: String, none: String) -> some View {
        VStack(alignment:.leading, spacing:3) {
            if t.available {
                Toggle(isOn:Binding(get:{ t.enabled }, set:{ save([key:$0]) })) {
                    HStack(spacing:6) { Text(title).font(.callout.weight(.medium)); badge(verified:t.verified) }
                }.toggleStyle(.checkbox).tint(Brand.accent).disabled(busy)
                Text(origin(t)).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 20)
            } else {
                HStack(spacing:6) { Text(title).font(.callout.weight(.medium)); Text(none).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func origin(_ t: CommunityTable) -> String {
        var parts: [String] = []
        if !t.sources.isEmpty { parts.append(L("社区：") + t.sources.prefix(2).joined(separator:"、") + (t.sources.count > 2 ? L(" 等") : "")) }
        if t.relocate { parts.append(L("版本与你的游戏不同，编译时按特征跨版本定位")) }
        return parts.joined(separator:" · ")
    }

    @ViewBuilder private func graphics(_ items: [CommunityGfx]) -> some View {
        VStack(alignment:.leading, spacing:6) {
            Text(L("画面")).font(.callout.weight(.medium))
            if items.isEmpty { Text(L("没有可用补丁")).font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { it in
                VStack(alignment:.leading, spacing:2) {
                    HStack(spacing:6) {
                        if it.exclusive.isEmpty {
                            Toggle(isOn:Binding(get:{ it.enabled }, set:{ save(["graphics":[it.id:$0]]) })) { Text(L(it.label)).font(.callout) }
                                .toggleStyle(.checkbox).tint(Brand.accent).disabled(busy)
                        } else {
                            Button { if !it.enabled { save(["graphics":[it.id:true]]) } } label:{
                                HStack(spacing:6) {
                                    Image(systemName:it.enabled ? "largecircle.fill.circle" : "circle").foregroundStyle(it.enabled ? Brand.accent : .secondary)
                                    Text(L(it.label)).font(.callout)
                                }
                            }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(it.enabled ? .isSelected : [])
                        }
                        badge(verified:it.state == "verified")
                    }
                    if it.state != "verified" && it.enabled {
                        Label(L("未经 S2Arm 验证，可能花屏或崩溃；出问题关掉即可"), systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.leading, 20)
                    } else if it.relocate {
                        Text(L("版本与你的游戏不同，编译时按特征跨版本定位")).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func badge(verified: Bool) -> some View {
        Text(verified ? L("已验证") : L("社区未验证")).font(.caption2.weight(.semibold))
            .padding(.horizontal,7).padding(.vertical,2)
            .foregroundStyle(verified ? Color.white : Color.secondary)
            .background(verified ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.clear), in:Capsule())
            .overlay(Capsule().strokeBorder(verified ? Color.clear : Color.secondary.opacity(0.5)))
    }

    private var info: some View {
        VStack(alignment:.leading, spacing:8) {
            Text(L("社区资源")).font(.headline)
            Text(L("宽屏和 60 帧是 S2Arm 自己的能力（从开源社区的补丁里学成的通用规律），按你的游戏版本匹配；匹配不到就自动不用。")).font(.callout)
            Text(L("包里不带社区补丁的原始数据。宽屏和 60 帧在这里（或 iPhone 的 App 设置）开关，下次启动生效，不用重新编译。")).font(.callout)
            Text(L("「已验证」= S2Arm 在 Mac 闭环和真机截图上量化验过；「社区未验证」可以自己打开试，出问题关掉即可。")).font(.callout)
        }.padding(16).frame(width:320)
    }
}
