// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Testing
@testable import ShellUI
@testable import S2ArmShellHost

@MainActor @Test func libraryOrderPersistsAndReconcilesCatalogue() throws {
    let suite = "s2a.test.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: defaults)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tiles = (1...4).map { GameTile(id: String(format: "%016X", $0), title: "Game \($0)") }
    let ids = tiles.map(\.id)
    func model(_ entries: [GameTile]) -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: Catalogue(tiles: entries, problems: []), stores: stores,
                           installState: { _ in 1 }, gamesRoot: root)
    }
    let first = model(Array(tiles.prefix(3)))
    #expect(first.games.map(\.id) == Array(ids.prefix(3)))
    let move = try #require(first.actions.onReorderGames)
    #expect(move([ids[0]], nil))
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    first.refreshGameData()
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    let reopened = model(tiles)
    #expect(reopened.games.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    let moveBack = try #require(reopened.actions.onReorderGames)
    #expect(moveBack([ids[0]], ids[1]))
    #expect(reopened.games.map(\.id) == ids)
    #expect(!moveBack([ids[0]], ids[0]))
    #expect(!moveBack(["unknown"], ids[1]))
    #expect(!moveBack([ids[0]], "unknown"))
    #expect(reopened.games.map(\.id) == ids)
    defaults.set([ids[2], ids[2], "removed", ids[0]], forKey: "S2ALibraryOrder")
    #expect(model(tiles).games.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    #expect(model([tiles[1], tiles[3]]).games.map(\.id) == [ids[1], ids[3]])
}

@MainActor @Test func carouselTitleTracksCentreBeforeScrollSettles() {
    let games = (1...5).map { GameDetail(game: GameTile(id: "\($0)", title: "Title \($0)")) }
    func title(_ offset: CGFloat, selected: Int = 0, scrolling: Bool = true) -> String {
        CoverFlowSelection.game(games: games, selected: games[selected], offset: offset, stride: 100, scrolling: scrolling).game.title
    }
    #expect(title(49) == "Title 1")
    #expect(title(51) == "Title 2")
    #expect(title(260) == "Title 4")
    #expect(title(140, selected: 3) == "Title 2")
    #expect(title(-80) == "Title 1")
    #expect(title(700) == "Title 5")
    #expect(title(100, selected: 3, scrolling: false) == "Title 4")
    #expect(CoverFlowSelection.game(games: [], selected: games[0], offset: 100, stride: 100, scrolling: true).id == "1")
}

@MainActor @Test func nativeReorderCommitsInsertionAndPersists() throws {
    let suite = "s2a.test.native-order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = (1...5).map { GameTile(id: "\($0)", title: "Game \($0)") }
    let stores = S2ArmGameSettings.Stores(game: { _ in nil }, app: defaults)
    func model() -> S2ArmShellHostModel {
        S2ArmShellHostModel(catalogue: Catalogue(tiles: tiles, problems: []), stores: stores,
                           installState: { _ in 1 })
    }
    let library = model()
    let reorder = try #require(library.actions.onReorderGames)
    // Native reordering previews positions without changing the model until the drop callback.
    #expect(defaults.stringArray(forKey: "S2ALibraryOrder") == nil)
    #expect(reorder(["1"], "4"))
    #expect(library.games.map(\.id) == ["2", "3", "1", "4", "5"])
    #expect(reorder(["3", "1"], nil))
    #expect(library.games.map(\.id) == ["2", "4", "5", "3", "1"])
    #expect(reorder(["5"], "2"))
    #expect(model().games.map(\.id) == ["5", "2", "4", "3", "1"])
    let saved = defaults.stringArray(forKey: "S2ALibraryOrder")
    #expect(!reorder([], nil))
    #expect(!reorder(["5", "5"], nil))
    #expect(!reorder(["unknown"], nil))
    #expect(!reorder(["5"], "unknown"))
    #expect(!reorder(["5"], "5"))
    #expect(defaults.stringArray(forKey: "S2ALibraryOrder") == saved)
}

@MainActor @Test func nativeReorderRejectsHiddenItemsAndKeepsPendingGames() throws {
    let suite = "s2a.test.native-hidden.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = (1...4).map { GameTile(id: "\($0)", title: "Game \($0)") }
    var ready = Set(["1", "3", "4"])
    let model = S2ArmShellHostModel(catalogue: Catalogue(tiles: tiles, problems: []),
        stores: .init(game: { _ in nil }, app: defaults), installState: { ready.contains($0) ? 1 : 0 })
    let reorder = try #require(model.actions.onReorderGames)
    #expect(!reorder(["1", "2"], "4"))
    #expect(!reorder(["1"], "2"))
    #expect(model.games.map(\.id) == ["1", "3", "4"])
    #expect(reorder(["4"], "1"))
    ready.insert("2")
    model.refreshGameData()
    #expect(model.games.map(\.id) == ["4", "1", "2", "3"])
}

@Test func listReorderConvertsOriginalOffsetsToStableInsertionIDs() throws {
    let ids = ["a", "b", "c", "d", "e"]
    let down = try #require(GameOrderMove(ids: ids, offsets: IndexSet(integer: 0), destination: 3))
    #expect(down.sources == ["a"])
    #expect(down.before == "d")
    let up = try #require(GameOrderMove(ids: ids, offsets: IndexSet(integer: 4), destination: 0))
    #expect(up.before == "a")
    let end = try #require(GameOrderMove(ids: ids, offsets: IndexSet([1, 3]), destination: 5))
    #expect(end.sources == ["b", "d"])
    #expect(end.before == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 1), destination: 2) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(), destination: 1) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 5), destination: 0) == nil)
    #expect(GameOrderMove(ids: ids, offsets: IndexSet(integer: 0), destination: 6) == nil)
}
