// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Combine
import Foundation
import S2ArmAppleAdapter

enum HomeGroup: String, CaseIterable {
    case all, ready, recent, favorites

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .ready: return "checkmark.circle"
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "heart"
        }
    }
}

@MainActor final class HomeLibraryState: ObservableObject {
    @Published var group: HomeGroup = .all
    @Published var search = ""
    @Published private(set) var favorites: Set<String>
    @Published private(set) var recent: [String]
    private let store: UserDefaults
    private var searchKeys: [String: (name: String, key: String)] = [:]
    private static let favoritesKey = "S2ArmHomeFavorites"
    private static let recentKey = "S2ArmHomeRecent"

    init(store: UserDefaults = .standard) {
        self.store = store
        favorites = Set(store.stringArray(forKey: Self.favoritesKey) ?? [])
        recent = store.stringArray(forKey: Self.recentKey) ?? []
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        store.set(favorites.sorted(), forKey: Self.favoritesKey)
    }
    func recordPlay(_ id: String) {
        guard recent.first != id else { return }
        recent = [id] + recent.filter { $0 != id }.prefix(99)
        store.set(recent, forKey: Self.recentKey)
    }
    func cycle(_ step: Int) {
        let groups = HomeGroup.allCases
        let index = groups.firstIndex(of: group) ?? 0
        group = groups[(index + step % groups.count + groups.count) % groups.count]
    }
    func games(_ all: [GameSummary]) -> [GameSummary] {
        var result = all
        switch group {
        case .all: break
        case .ready: result = result.filter(\.playable)
        case .favorites: result = result.filter { favorites.contains($0.id) }
        case .recent:
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result = recent.compactMap { byID[$0] }
        }
        let query = Self.searchKey(search)
        if !query.isEmpty {
            result = result.filter { game in
                if searchKeys[game.id]?.name != game.name { searchKeys[game.id] = (game.name, Self.searchKey(game.name)) }
                return searchKeys[game.id]!.key.contains(query) || game.id.localizedCaseInsensitiveContains(search)
            }
        }
        return result
    }
    static func searchKey(_ value: String) -> String {
        (value.applyingTransform(.toLatin, reverse: false) ?? value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }
}
