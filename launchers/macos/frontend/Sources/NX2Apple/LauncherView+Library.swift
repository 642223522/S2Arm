// Derived from NX2Apple LauncherView+Library.swift (908e4e84, MIT; see ../../UPSTREAM.md).
// S2Arm: the Home layout lives in LauncherView+Home; this file keeps library status,
// management actions and file drops shared with that layout.
import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

extension LauncherView {
    var libraryPage: some View {
        GeometryReader { geometry in
            if model.games.isEmpty && !model.libraryLoaded {
                loadingLibrary
            } else if model.showsWelcome {
                emptyLibrary
            } else {
                homeLibrary(size: geometry.size)
            }
        }
    }

    /// 第一次读游戏库还没回来：只显示「正在读取」，不先闪「还没有游戏」（11-07 界面验收）。
    var loadingLibrary: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text(loc.t("s2arm.library.loading")).font(.manrope(15)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 游戏库还是空的：欢迎页兼环境检查（11-08 维护者），有游戏后回到游戏库。
    var emptyLibrary: some View {
        WelcomeView(model: model)
    }

    func cardTargeted(_ id: String) -> Binding<Bool> {
        Binding(get: { dropCard == id }, set: { dropCard = $0 ? id : (dropCard == id ? nil : dropCard) })
    }
    static let gameFileTypes: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]   // 同后端 pack/jobs/library.py SOURCE_SUFFIXES（#611：漏了 Switch 2 的 .nup，拖到卡片上会被当成存档）
    func dropOnCard(_ urls: [URL], game: GameSummary) {
        guard let first = urls.first else { return }
        let ext = first.pathExtension.lowercased()
        if urls.count == 1, ext == "keys" { model.importKeys(first); return }
        if urls.contains(where: { Self.gameFileTypes.contains($0.pathExtension.lowercased()) }) { model.importGames(urls, partialResults: true); return }
        saveDrop = first; saveFor = game.id
    }

    /// 显示的是上次的列表（刷新失败）：标明是上次的、说原因、给重试。后台正常刷新时只在顶栏转轻菊花，避免首屏横幅占位导致封面排下移再上跳。
    @ViewBuilder var staleBanner: some View {
        if model.showingSnapshot && !model.games.isEmpty && model.libraryError != nil {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(LauncherPalette.danger)
                Text(txt("library.stale.failed").replacingOccurrences(of: "{0}", with: loc.backend(model.staleLibraryError ?? ""))).font(.manrope(13.5, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(txt("library.stale.retry")) { model.refresh() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("library.stale.retry")
            }
            .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 10).background(LauncherPalette.danger.opacity(0.10))
        }
    }

    /// 免费签名快到期 / 已到期的提醒（只提最急的一款）。
    @ViewBuilder var renewBanner: some View {
        if let game = model.games.filter({ ($0.iphoneDaysLeft() ?? 9) <= 1 }).min(by: { ($0.iphoneDaysLeft() ?? 9) < ($1.iphoneDaysLeft() ?? 9) }), let days = game.iphoneDaysLeft() {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(LauncherPalette.building)
                Text((days == 0 ? txt("library.banner.expired") : txt("library.banner.renew")).replacingOccurrences(of: "{0}", with: game.name).replacingOccurrences(of: "{1}", with: "\(days)")).font(.manrope(13.5, .semibold))
                Spacer(minLength: 12)
                Button(txt("library.hero.renew")) { model.targetInstalledDevice(of: game); installFor = game.id }.controllerButtonStyle(LauncherSecondaryButtonStyle())
            }
            .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 10).background(LauncherPalette.building.opacity(0.10))
        }
    }

    func moreMenu(_ game: GameSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 6) {
                Text(txt("library.sizes.title")).font(.manrope(11, .semibold)).foregroundStyle(.secondary)
                GameSizesList(sizes: game.sizes, compact: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider().opacity(0.3).padding(.vertical, 4)
            if model.finishedExports[game.id] != nil, !(model.mainBusy && model.session?.gameID == game.id) {   // 这款上次出包 / 装机 / 导出的结果页（原首页圆钮）
                moreRow(txt("library.hero.results"), "checkmark.seal") { model.viewingResult = model.finishedExports[game.id] }
            }
            if game.appleTvReady {   // #1429：出好 Apple TV 包的款，游戏库里也有「装到 Apple TV」（原先只在出包页 / 出包结果页，离开就找不到）
                moreRow(BackendText.launcherText("export.installAppleTV", language: loc.lang.sharedCode), "appletv") { model.installAppleTV(game) }
                    .disabled(model.busy)
            }
            moreRow(loc.t("s2arm.action.freeSpace"), "externaldrive") { spaceFor = game.id }
            moreRow(txt("game.display"), "slider.horizontal.3") { displayFor = game.id }
            moreRow(txt("game.saves"), "tray.full") { saveFor = game.id }
            moreRow(txt("game.input"), "gamecontroller") { inputFor = game.id }
            moreRow(txt("game.diag"), "paperplane") { model.diagUploadFor = game.id }   // 上传给开发者；上传没成在弹窗里退回导出
            if !game.location.path.isEmpty {
                moreRow(txt("library.menu.reveal"), "folder") { model.reveal(game) }
            }
            Divider().opacity(0.3).padding(.vertical, 4)
            moreRow(txt("game.delete"), "trash", danger: true) { deleteFor = game }
        }
        .padding(8).frame(width: 220).font(.manrope(13.5, .semibold)).preferredColorScheme(.dark)
    }

    private func moreRow(_ title: String, _ symbol: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        let activate = { moreFor = nil; action() }
        return Button(action: activate) {
            MoreMenuRowLabel(title: title, symbol: symbol, danger: danger)
        }
        .buttonStyle(.plain)
        .controllerControl(activate: activate)
    }

    /// 游戏卡片右键菜单（游戏库结构 v3）：开始游戏、出包、启动设置、在访达中显示、移动到其他位置、清除缓存、删除
    @ViewBuilder func cardMenu(_ game: GameSummary) -> some View {
        let reachable = game.location.state != "offline" && game.location.state != "missing"
        if game.playable && reachable {
            Button { model.play(game, uiLanguage: uiLanguage) } label: { Label(loc.t("library.play"), systemImage: "play.fill") }
        }
        Button { model.exportFor = game.id } label: { Label(loc.t("s2arm.export.action"), systemImage: "shippingbox") }.disabled(!reachable)
        Button { displayFor = game.id } label: { Label(txt("library.menu.launchSettings"), systemImage: "gearshape") }.disabled(!reachable)
        Divider()
        Button { model.reveal(game) } label: { Label(txt("library.menu.reveal"), systemImage: "folder") }.disabled(game.location.path.isEmpty)
        Button { moveGame(game) } label: { Label(txt("library.menu.move"), systemImage: "arrow.right.doc.on.clipboard") }.disabled(!reachable || game.location.state == "none" || model.busy)
        Button { model.clearCache(game) } label: { Label(txt("library.menu.clearCache"), systemImage: "sparkles") }.disabled(!reachable || model.busy)
        Divider()
        Button(role: .destructive) { deleteFor = game } label: { Label(txt("game.delete"), systemImage: "trash") }
    }

    func moveGame(_ game: GameSummary) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = BackendText.launcherText("export.location.choose", language: uiLanguage)
        if panel.runModal() == .OK, let url = panel.url { model.moveGame(game, to: url) }
    }

    func relinkGame(_ game: GameSummary) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = txt("library.missing.pick")
        if panel.runModal() == .OK, let url = panel.url { model.relinkGame(game, folder: url) }
    }

    /// 卡片和大图上的状态：两端都算（原作者只看 Mac 版）。
    func statusLine(_ game: GameSummary) -> (text: String, color: Color) {
        if model.mainBusy && model.session?.gameID == game.id {
            return (loc.t(model.session?.kind == .play ? "s2arm.library.running" : "s2arm.job.running"), LauncherPalette.building)
        }
        if model.exportQueue.contains(where: { $0.game.id == game.id }) { return (txt("export.status.queued"), LauncherPalette.building) }
        // 存放位置（游戏库结构 v3）：移动硬盘没插 → 灰色「未连接」，插回来自动恢复；文件夹没了 → 红字，点卡片重新指定或移除
        // 未连接给具体路径（同出包页下拉框）：卷名会重名（内置盘一律「系统盘」），看不出是哪个位置没连上
        if game.location.state == "offline" {
            let place = game.location.path.isEmpty ? game.location.volume : (game.location.path as NSString).abbreviatingWithTildeInPath
            return (txt("library.location.offline").replacingOccurrences(of: "{0}", with: place), LauncherPalette.unbuilt)
        }
        if game.location.state == "missing" { return (txt("library.location.missing"), LauncherPalette.danger) }
        var parts: [String] = []
        var expired = false
        if game.iphoneInstalledAt != nil {
            if let days = game.iphoneDaysLeft() {
                expired = days == 0
                parts.append(expired ? txt("library.status.expired") : txt("library.status.installed").replacingOccurrences(of: "{0}", with: "\(days)"))
            } else { parts.append(txt("library.status.installedPaid")) }
        } else if game.iphoneReady { parts.append(txt("library.status.iphone")) }
        if game.playable { parts.append(loc.t("library.ready")) }
        if parts.isEmpty { return (loc.t("s2arm.library.notPrepared"), LauncherPalette.unbuilt) }
        return (parts.joined(separator: " · "), expired ? LauncherPalette.danger : LauncherPalette.ready)
    }

    func status(_ game: GameSummary, prominent: Bool = false) -> some View {
        let (text, color) = statusLine(game)
        return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: prominent ? 9 : 7, height: prominent ? 9 : 7)
            Text(prominent ? text.uppercased() : text)
                .font(prominent ? .manrope(12, .bold) : .manrope(13, .medium))
                .tracking(prominent ? 1.3 : 0)
                .foregroundStyle(color)
            if !game.display.isEmpty {
                Text("· " + game.display).font(.manrope(prominent ? 13 : 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // 导入时数据校验不过、照常导入的款（11-17）：选中时黄字说一句（卡片角标只有图标，手柄玩家看不到悬停说明）
        if game.integritySkipped {
            Label(loc.backend(LauncherView.integritySkippedNote), systemImage: "exclamationmark.triangle.fill")
                .font(.manrope(12, .medium)).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
        }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A cover filling its frame (upstream ArtworkFill without the focus point: S2Arm covers have none).
struct CoverFill: View {
    let image: NSImage
    var body: some View {
        // 填满后溢出的部分 .clipped() 只裁显示、不裁点击区域：不限定的话，接近正方形的封面会把点击区域伸出框外，
        //   盖住上面的「返回游戏库」、旁边的卡片（11-09 维护者：丝之歌出包页返回点不了；AX 量到封面按钮高 236、看得见的只有 131）。
        //   用 Color.clear.overlay 代替 GeometryReader，避免卡片从小变大时 GeometryReader 尺寸一步到位跳过插值动画
        Color.clear
            .overlay {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// Artwork I/O runs off the UI thread. A slow volume must not block selection or window layout.
/// Cache by path + target modification time; retry missing/invalid artwork when its file changes.
@MainActor final class CoverCache: ObservableObject {
    struct Loaded {
        let version: String
        let image: NSImage?
        var decoded = false
    }
    typealias Loader = (String, String?) -> Loaded
    private var images: [String: NSImage] = [:]
    private var versions: [String: String] = [:]
    private var pending: Set<String> = []
    private let loader: Loader
    @Published private var revision = 0

    init(loader: @escaping Loader = CoverCache.load) { self.loader = loader }

    func image(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if pending.insert(path).inserted {
            let previous = versions[path], loader = loader
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = loader(path, previous)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(path)
                    guard self.versions[path] != result.version else { return }
                    self.versions[path] = result.version
                    self.images[path] = result.image
                    if result.decoded { LauncherWork.count(.artworkDecode) }
                    self.revision &+= 1
                }
            }
        }
        return images[path]
    }

    nonisolated private static func load(_ path: String, _ previous: String?) -> Loaded {
        // Only the target timestamp is needed, not Foundation's extra extended-attribute queries.
        var metadata = stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &metadata, 0) }) == 0 else { return Loaded(version: "", image: nil) }
        let version = String(metadata.st_mtimespec.tv_sec) + "." + String(metadata.st_mtimespec.tv_nsec)
        guard version != previous else { return Loaded(version: version, image: nil) }
        // Read the bytes here: NSImage(contentsOfFile:) can defer file access until main-thread drawing.
        let image = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(NSImage.init(data:))
        _ = image?.representations
        return Loaded(version: version, image: image, decoded: true)
    }
}

/// 游戏卡片的拖放落点：拖着文件经过时封面描虚线，放下交给 perform（LauncherView.dropOnCard）。
struct CardDrop: ViewModifier {
    let targeted: Binding<Bool>
    let artwork: CGFloat
    let perform: ([URL]) -> Void
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted.wrappedValue {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(LauncherPalette.cream, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(height: artwork).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: targeted) { providers in
                LauncherView.fileURLs(providers, perform)
                return true
            }
    }
}

private struct MoreMenuRowLabel: View {
    let title: String
    let symbol: String
    let danger: Bool
    @State private var hovered = false

    var body: some View {
        // 图标放固定宽度的框里、和文字按中线对齐：Label 的图标宽度跟着符号走，各行文字起点会错开（11-09 维护者截图）
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20, height: 20, alignment: .center)
            Text(title).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .foregroundStyle(danger ? LauncherPalette.danger : Color.primary)
        .onHover { hovered = $0 }
    }
}
