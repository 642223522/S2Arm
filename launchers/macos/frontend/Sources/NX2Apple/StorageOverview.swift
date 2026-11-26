// S2Arm（不是上游文件）：游戏库结构 v3「查」：每款四项大小（catalog sizes，作业收尾量好的，不现场量）与存储总览（storageOverview 作业）。
// 四项大小显示在游戏库「更多」菜单顶上；总览是「释放空间」页的第二页：各存放位置的 S2Arm 占用 / 剩余 / 总量、公共文件、各款大小。
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func size(_ bytes: Int64) -> String { FreeSpaceView.size(bytes) }

/// 一款的四项大小 + 原件（共用的按款数平摊）。没量过显示「未统计」。
struct GameSizesList: View {
    @EnvironmentObject var loc: Localizer
    let sizes: GameSizes
    var compact = false

    private func t(_ id: String) -> String { BackendText.launcherText("library.sizes." + id, language: loc.lang.sharedCode) }

    /// 0.6.0 四类（作业层带了 categories）：资源、程序、玩家数据、缓存 + 原件；没带照旧五项
    static func rows(_ s: GameSizes) -> [(id: String, bytes: Int64)] {
        if let c = s.categories { return GameSizes.categoryOrder.map { ($0, c[$0] ?? 0) } + [("sources", s.sources)] }
        return [("imageMac", s.imageMac), ("imageIos", s.imageIos), ("saves", s.saves), ("cache", s.cache), ("sources", s.sources)]
    }

    /// 悬停说明：原件说平摊；四类说「删了会怎样」
    private func note(_ id: String) -> String {
        if id == "sources" { return t("sourcesNote") }
        return sizes.categories != nil ? t(id + "Note") : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            ForEach(Self.rows(sizes), id: \.id) { row in
                HStack {
                    Text(t(row.id)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(sizes.measured || row.id == "sources" ? size(row.bytes) : "-").monospacedDigit()
                }
                .help(note(row.id))
            }
            if !sizes.measured {
                Text(t("unmeasured")).font(.manrope(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.manrope(compact ? 12 : 13))
    }
}

/// 存储总览：进来先起一次 storageOverview（作业层会补量没量过的款）。
struct StorageOverviewSection: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer

    private func t(_ id: String) -> String { BackendText.launcherText("storage." + id, language: loc.lang.sharedCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error = model.overviewError {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            if let o = model.overview {
                CardGroup(t("locations")) {
                    ForEach(o.locations) { l in
                        // 行首给具体路径（不再给卷名、路径缩到副行）：几行都叫「系统盘」分不清（名字同出包页下拉框 locationName）
                        CardRow(S2ArmLauncherModel.locationName(path: l.path, volume: l.volume), detail: detail(l), dot: l.connected ? LauncherPalette.ready : LauncherPalette.unbuilt) {
                            Text(l.isDefault ? t("location.default") : "").font(.manrope(12)).foregroundStyle(.secondary)
                        }
                        if l.id != o.locations.last?.id { CardDivider() }
                    }
                }
                CardGroup(t("shared")) {
                    ForEach(o.shared) { part in
                        CardRow(t("shared." + part.id)) {
                            Text(size(part.bytes)).font(.manrope(13, .semibold)).monospacedDigit()
                        }
                        if part.id != o.shared.last?.id { CardDivider() }
                    }
                }
                // 0.6.0 四类时多一句：这里是盘上真实占用，访达显示逻辑大小（克隆、硬链接不额外占盘）
                CardGroup(t("games"), footnote: BackendText.launcherText("library.sizes.sourcesNote", language: loc.lang.sharedCode)
                          + (o.games.contains { $0.sizes.categories != nil } ? "\n" + t("finderNote") : "")) {
                    ForEach(o.games) { g in
                        // 游戏名和设置行共用同一条文字起始线。
                        HStack(alignment: .top, spacing: LauncherTheme.Space.medium) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(g.name).font(.manrope(14, .semibold)).fixedSize(horizontal: false, vertical: true)
                                GameSizesList(sizes: g.sizes, compact: true)
                            }
                        }
                        .padding(.horizontal, LauncherTheme.Metrics.cardInset).padding(.vertical, LauncherTheme.Space.large)
                        if g.id != o.games.last?.id { CardDivider() }
                    }
                }
            } else if model.overviewLoading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(t("loading")).foregroundStyle(.secondary) }
            }
        }
        .onAppear { model.loadOverview() }
    }

    private func detail(_ l: StorageOverview.Location) -> String {
        guard l.connected, let free = l.freeBytes, let total = l.totalBytes else { return t("location.offline") }
        return t("location.usage").replacingOccurrences(of: "{0}", with: size(l.usedBytes ?? 0))
            .replacingOccurrences(of: "{1}", with: size(free)).replacingOccurrences(of: "{2}", with: size(total))
    }
}
