// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import UniformTypeIdentifiers

private struct GameReorderItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "io.s2arm.library-game"))
    }
}

private struct ShellMoveGameKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((String, String) -> Bool)? = nil
}

private struct ShellReorderGamesKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (([String], String?) -> Bool)? = nil
}

private struct ShellOpenGameOrderKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var shellOpenGameOrder: (() -> Void)? {
        get { self[ShellOpenGameOrderKey.self] }
        set { self[ShellOpenGameOrderKey.self] = newValue }
    }
    var shellMoveGame: ((String, String) -> Bool)? {
        get { self[ShellMoveGameKey.self] }
        set { self[ShellMoveGameKey.self] = newValue }
    }
    var shellReorderGames: (([String], String?) -> Bool)? {
        get { self[ShellReorderGamesKey.self] }
        set { self[ShellReorderGamesKey.self] = newValue }
    }
}

extension DynamicViewContent {
    @ViewBuilder func shellReorderable() -> some View {
        if #available(iOS 27, macOS 27, *) {
            reorderable()
        } else {
            self
        }
    }
}

/// The system animates the insertion gap and edge scrolling, then supplies one final move on drop.
struct GameReorderContainer: ViewModifier {
    @Environment(\.shellReorderGames) private var reorder

    func body(content: Content) -> some View {
        if #available(iOS 27, macOS 27, *) {
            content.reorderContainer(for: GameDetail.self, isEnabled: reorder != nil) { difference in
                switch difference.destination.position {
                case .before(let id): _ = reorder?(difference.sources, id)
                case .end: _ = reorder?(difference.sources, nil)
                }
            }
        } else {
            content
        }
    }
}

struct GameOrderButton: View {
    @Environment(\.shellOpenGameOrder) private var open

    var body: some View {
        if let open {
            Button(action: open) {
                Label(ShellStrings.text("Reorder"), systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityIdentifier("library.reorder")
            .shellTarget("lib.reorder", radius: 22, action: open)
        }
    }
}

/// A flat grid gives each card a disjoint hit region and lets the system own the complete landing animation.
struct GameOrderView: View {
    let games: [GameDetail]
    let move: ((String, String) -> Bool)?
    let reorder: (([String], String?) -> Bool)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(ShellStrings.text("Touch and hold a cover, then drag to reorder."))
                        .shellText(15).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 24)],
                              alignment: .leading, spacing: 24) {
                        ForEach(games) { detail in
                            VStack(alignment: .leading, spacing: 10) {
                                CoverView(game: detail.game, radius: 12, showsState: false)
                                Text(detail.game.title).shellType(ShellType.cardTitle)
                                    .lineLimit(2).frame(height: 44, alignment: .topLeading)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("reorder.tile.\(detail.id)")
                            .modifier(GameReorderCard(id: detail.id))
                        }.shellReorderable()
                    }
                    .modifier(GameReorderContainer())
                }.padding(24)
            }
            .background(ShellPalette.background)
            .navigationTitle(ShellStrings.text("Reorder games"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ShellStrings.text("Done")) { dismiss() }
                        .accessibilityIdentifier("reorder.done")
                }
            }
        }
        .tint(ShellPalette.cream)
        .environment(\.shellMoveGame, move)
        .environment(\.shellReorderGames, reorder)
    }
}

/// Earlier systems retain the single-card drop interaction.
struct GameReorderCard: ViewModifier {
    let id: String
    @Environment(\.shellMoveGame) private var move
    @Environment(\.shellReorderGames) private var reorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    func body(content: Content) -> some View {
        if #available(iOS 27, macOS 27, *), reorder != nil {
            content
        } else {
            legacyDrop(content)
        }
    }

    @ViewBuilder private func legacyDrop(_ content: Content) -> some View {
        if let move {
            content
                .draggable(GameReorderItem(id: id))
                .dropDestination(for: GameReorderItem.self) { items, _ in
                    guard items.count == 1, let item = items.first, item.id != id else { return false }
                    return withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { move(item.id, id) }
                } isTargeted: { targeted = $0 }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(ShellPalette.cream, lineWidth: targeted ? 3 : 0)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}
