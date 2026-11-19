#if !os(tvOS)   // S2Arm（不是上游文件）：电视版游戏库没有快照入口
import SwiftUI

/// "Continue from this moment" (0.6.0, decided 11-19): the games with a saved moment, newest first. One list in two shapes:
/// a row under the hero when the library is upright, a column on the leading side beside the cover flow when it is wider
/// than tall (iPhone on its side, iPad in landscape) — there the screen is short of height, not width, and a row on top
/// would take half the card's height. A tap goes straight back to that moment (asking first when the game saved after it).
/// A long press offers Delete this moment with the space it takes; one confirmation, then it goes. No saved moment
/// anywhere: nothing is drawn at all.
struct SavedMomentStrip: View {
    let games: [GameDetail]
    let axis: Axis
    var short = false
    @Environment(\.shellSnapshot) private var snapshot
    /// The saved moment the player chose to delete, waiting for the confirmation.
    @State private var deleting: GameDetail?

    /// The games to list: a complete saved moment and playable, newest first.
    static func saved(_ games: [GameDetail]) -> [GameDetail] {
        games.filter { $0.game.moment != nil && $0.game.state == .playable }
            .sorted { ($0.game.moment?.savedAt ?? .distantPast) > ($1.game.moment?.savedAt ?? .distantPast) }
    }

    var body: some View {
        let saved = Self.saved(games)
        if let snapshot, !saved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: ShellStrings.text("Continue from this moment")).padding(.horizontal, axis == .horizontal ? 24 : 0)
                ScrollView(axis == .horizontal ? .horizontal : .vertical) {
                    let cards = ForEach(saved) { detail in card(detail, restore: snapshot.restore) }
                    if axis == .horizontal { HStack(alignment: .top, spacing: 14) { cards }.padding(.vertical, 4) }
                    else { VStack(alignment: .leading, spacing: 10) { cards }.padding(.bottom, 12) }
                }
                .contentMargins(.horizontal, axis == .horizontal ? 24 : 0, for: .scrollContent)
                .scrollIndicators(.hidden)
                .clipped()
            }
            // Deleting loses the moment for good: one confirmation, then it goes (decided 11-19). The size is what it frees.
            .alert(ShellStrings.text("Delete the saved moment?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { detail in
                Button(ShellStrings.text("Cancel"), role: .cancel) {}
                Button(ShellStrings.text("Delete this moment"), role: .destructive) { snapshot.delete?(detail.id) }
            } message: { detail in
                Text(String(format: ShellStrings.text("It takes about %@. Once deleted you can’t go back to that moment. Your game saves are not affected."),
                            Self.size(detail.game.moment?.bytes ?? 0)))
            }
        }
    }

    private func card(_ detail: GameDetail, restore: @escaping (String) -> Void) -> some View {
        let width: CGFloat? = axis == .horizontal ? (short ? 128 : 150) : nil   // the column: as wide as the column
        let when = detail.game.moment.map { Self.time($0.savedAt) } ?? ""
        return Button { restore(detail.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let picture = detail.game.moment?.picture {
                            Image(decorative: picture.image, scale: 1).resizable().interpolation(.high).scaledToFill()
                        } else {
                            CoverView(game: detail.game, radius: 0)
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.game.title).shellText(13, .semibold).foregroundStyle(.white).lineLimit(1)
                    Text(when).shellText(11.5).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShellStrings.text("Continue from this moment") + ", " + detail.game.title + ", " + when)
        .accessibilityIdentifier("moment.\(detail.id)")
        .shellTarget("lib.moment.\(detail.id)") { restore(detail.id) }
        .contextMenu {   // 长按：删除这一刻，标出占多少空间
            if snapshot?.delete != nil {
                Button(role: .destructive) { deleting = detail } label: {
                    Label(ShellStrings.text("Delete this moment"), systemImage: "trash")
                    Text(String(format: ShellStrings.text("About %@"), Self.size(detail.game.moment?.bytes ?? 0)))
                }
            }
        }
    }

    /// "Today 14:32", "Yesterday 22:10", or the date: the moment's wall-clock time in the player's locale.
    static func time(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter(); f.locale = locale; f.doesRelativeDateFormatting = true; f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }

    /// "820 MB": the space a saved moment takes, as Files shows sizes.
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// The column's width beside the cover flow: about a quarter of the screen, wider on a tablet.
    static func columnWidth(_ width: CGFloat, regular: Bool) -> CGFloat { min(regular ? 260 : 200, max(140, width * (regular ? 0.24 : 0.23))) }
}
#endif
