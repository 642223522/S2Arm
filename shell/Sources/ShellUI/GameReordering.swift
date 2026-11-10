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

extension EnvironmentValues {
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
    @Binding var isReordering: Bool
    @Environment(\.shellReorderGames) private var reorder

    init(isReordering: Binding<Bool> = .constant(false)) {
        _isReordering = isReordering
    }

    func body(content: Content) -> some View {
        if #available(iOS 27, macOS 27, *) {
            content.reorderContainer(for: GameDetail.self, isEnabled: reorder != nil) { difference in
                switch difference.destination.position {
                case .before(let id): _ = reorder?(difference.sources, id)
                case .end: _ = reorder?(difference.sources, nil)
                }
            }
            .onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active: isReordering = true
                case .ended: isReordering = false
                default: break
                }
            }
        } else {
            content
        }
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
