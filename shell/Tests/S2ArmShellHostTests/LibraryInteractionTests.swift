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
                           gameDataReady: { _ in true }, gamesRoot: root)
    }
    let first = model(Array(tiles.prefix(3)))
    #expect(first.games.map(\.id) == Array(ids.prefix(3)))
    let move = try #require(first.actions.onMoveGame)
    #expect(move(ids[0], ids[2]))
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    first.refreshGameData()
    #expect(first.games.map(\.id) == [ids[1], ids[2], ids[0]])
    let reopened = model(tiles)
    #expect(reopened.games.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    let moveBack = try #require(reopened.actions.onMoveGame)
    #expect(moveBack(ids[0], ids[1]))
    #expect(reopened.games.map(\.id) == ids)
    #expect(!moveBack(ids[0], ids[0]))
    #expect(!moveBack("unknown", ids[1]))
    #expect(!moveBack(ids[0], "unknown"))
    #expect(reopened.games.map(\.id) == ids)
    defaults.set([ids[2], ids[2], "removed", ids[0]], forKey: "S2ALibraryOrder")
    #expect(model(tiles).games.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    #expect(model([tiles[1], tiles[3]]).games.map(\.id) == [ids[1], ids[3]])
}

@MainActor @Test func hiddenGamesKeepTheirPlaceWhenResourcesArrive() throws {
    let suite = "s2a.test.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tiles = (1...3).map { GameTile(id: String(format: "%016X", $0), title: "Game \($0)") }
    var ready = Set([tiles[0].id, tiles[2].id])
    let model = S2ArmShellHostModel(catalogue: Catalogue(tiles: tiles, problems: []),
        stores: .init(game: { _ in nil }, app: defaults), gameDataReady: { ready.contains($0) },
        gamesRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let move = try #require(model.actions.onMoveGame)
    #expect(!move(tiles[1].id, tiles[0].id))
    #expect(move(tiles[2].id, tiles[0].id))
    #expect(model.games.map(\.id) == [tiles[2].id, tiles[0].id])
    ready.insert(tiles[1].id)
    model.refreshGameData()
    #expect(model.games.map(\.id) == [tiles[2].id, tiles[0].id, tiles[1].id])
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
