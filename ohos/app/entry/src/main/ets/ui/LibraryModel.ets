// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
export class Game {
  key: string; title: string; subtitle: string; titleId: string; modules: string; version: string;
  favorite: boolean = false;
  addedAt: number = 0;
  lastPlayedAt: number = 0;
  constructor(key: string, title: string, subtitle: string, titleId: string, modules: string, version: string) {
    this.key = key; this.title = title; this.subtitle = subtitle;
    this.titleId = titleId; this.modules = modules; this.version = version;
  }
}

export function sortGames(games: Game[], order: string): Game[] {
  return games.slice().sort((a: Game, b: Game) => {
    if (order === 'favorite' && a.favorite !== b.favorite) return a.favorite ? -1 : 1;
    if (order !== 'title') {
      const activity = b.lastPlayedAt - a.lastPlayedAt || b.addedAt - a.addedAt;
      if (activity !== 0) return activity;
      return a.titleId.localeCompare(b.titleId);
    }
    return a.title.localeCompare(b.title) || a.titleId.localeCompare(b.titleId);
  });
}

// Pure functions shared by the production grid and offline regression tests.
export function filterGames(games: Game[], query: string): Game[] {
  const needle = query.trim().toLocaleLowerCase();
  return games.filter((game: Game) => game.title.toLocaleLowerCase().includes(needle) ||
    game.titleId.toLocaleLowerCase().includes(needle));
}

export function recentGames(games: Game[], lastKey: string): Game[] {
  const recent = games.find((game: Game) => game.key === lastKey);
  return recent ? [recent, ...games.filter((game: Game) => game.key !== lastKey)] : games.slice();
}
