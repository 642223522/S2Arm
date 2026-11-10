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

extension EnvironmentValues {
    var shellMoveGame: ((String, String) -> Bool)? {
        get { self[ShellMoveGameKey.self] }
        set { self[ShellMoveGameKey.self] = newValue }
    }
}

/// Native drag sessions cancel without changing the order. Only a drop on another game commits a move.
struct GameReorderCard: ViewModifier {
    let id: String
    @Environment(\.shellMoveGame) private var move
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    func body(content: Content) -> some View {
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
