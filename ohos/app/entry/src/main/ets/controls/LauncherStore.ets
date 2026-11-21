// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import { common } from '@kit.AbilityKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { PlayerSettings, loadPlayerSettings } from './PlayerSettings';
import { Game } from '../ui/LibraryModel';

export interface DisplayProfile {
  resolutionScale: string;
  scalingFilter: string;
  widenMode: string;
}

// No game resources/saves in this database. The filesystem remains import authority.
export class LauncherStore {
  private globals?: preferences.Preferences;
  private database?: relationalStore.RdbStore;
  private writes: Promise<void> = Promise.resolve();

  async open(context: common.UIAbilityContext): Promise<PlayerSettings> {
    this.globals = await preferences.getPreferences(context, { name: 'launcher-global-v1' });
    const legacy = loadPlayerSettings(context.filesDir);
    const stored = await this.globals.get('player', '');
    let settings = legacy;
    if (typeof stored === 'string' && stored.length > 0) {
      const parsed = JSON.parse(stored) as PlayerSettings;
      if (parsed.schema !== legacy.schema || typeof parsed.touchFeedback !== 'boolean' ||
          typeof parsed.gameFeedback !== 'boolean' || typeof parsed.hideTouchWithController !== 'boolean' ||
          typeof parsed.lastGame !== 'string') throw new Error('设置格式无效');
      settings = parsed;
    } else {
      await this.globals.put('player', JSON.stringify(legacy));
      await this.globals.flush(); // Legacy JSON retained for recovery; migration commits last.
    }
    this.database = await relationalStore.getRdbStore(context, {
      name: 'launcher-v1.db', securityLevel: relationalStore.SecurityLevel.S1
    });
    await this.database.executeSql('CREATE TABLE IF NOT EXISTS PlayProfile (gameKey TEXT PRIMARY KEY, payload TEXT NOT NULL, updatedAt INTEGER NOT NULL)');
    await this.database.executeSql(`CREATE TABLE IF NOT EXISTS games (
      titleId TEXT PRIMARY KEY, gameKey TEXT NOT NULL, displayName TEXT NOT NULL,
      coverPath TEXT, contentUri TEXT NOT NULL, sourceUri TEXT, contentVersion TEXT,
      contentFingerprint TEXT, status TEXT NOT NULL, statusReason TEXT,
      addedAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, lastPlayedAt INTEGER,
      favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)),
      playTimeMs INTEGER NOT NULL DEFAULT 0, hostCompatibilityVersion TEXT)`);
    return settings;
  }

  async indexGames(games: Game[], files: string): Promise<Game[]> {
    if (!this.database) throw new Error('游戏索引未就绪');
    const indexed: Game[] = [];
    for (const game of games) {
      const now = Date.now();
      const uri = 'file://' + files + '/games/' + game.key;
      await this.database.executeSql(`INSERT OR IGNORE INTO games
        (titleId, gameKey, displayName, contentUri, contentVersion, status, statusReason, addedAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, 'update', 'HOST_CHECK_REQUIRED', ?, ?)`,
        [game.titleId, game.key, game.title, uri, game.version, now, now]);
      await this.database.executeSql(`UPDATE games SET gameKey=?, displayName=?, contentUri=?,
        contentVersion=?, coverPath=?, updatedAt=? WHERE titleId=?`,
        [game.key, game.title, uri, game.version, uri + '/game/icon.jpg', now, game.titleId]);
      const rows = await this.database.querySql('SELECT favorite, addedAt, lastPlayedAt FROM games WHERE titleId=?', [game.titleId]);
      try {
        const copy = new Game(game.key, game.title, game.subtitle, game.titleId, game.modules, game.version);
        if (rows.goToFirstRow()) {
          copy.favorite = rows.getLong(0) === 1;
          copy.addedAt = rows.getLong(1);
          copy.lastPlayedAt = rows.isColumnNull(2) ? 0 : rows.getLong(2);
        }
        indexed.push(copy);
      } finally { rows.close(); }
    }
    return indexed;
  }

  async setFavorite(titleId: string, favorite: boolean): Promise<void> {
    if (!this.database) throw new Error('游戏索引未就绪');
    await this.database.executeSql('UPDATE games SET favorite=?, updatedAt=? WHERE titleId=?',
      [favorite ? 1 : 0, Date.now(), titleId]);
  }

  async markFirstFrame(titleId: string): Promise<void> {
    if (!this.database) throw new Error('游戏索引未就绪');
    await this.database.executeSql("UPDATE games SET lastPlayedAt=?, status='ready', statusReason=NULL WHERE titleId=?", [Date.now(), titleId]);
  }

  saveGlobals(settings: PlayerSettings): Promise<void> {
    const payload = JSON.stringify(settings);
    const action = this.writes.catch(() => {}).then(async () => {
      if (!this.globals) throw new Error('设置存储未就绪');
      await this.globals.put('player', payload);
      await this.globals.flush();
    });
    this.writes = action;
    return action;
  }

  async loadProfile(key: string): Promise<DisplayProfile> {
    if (!this.database) throw new Error('游戏设置未就绪');
    const result = await this.database.querySql('SELECT payload FROM PlayProfile WHERE gameKey = ?', [key]);
    try {
      if (!result.goToFirstRow()) return { resolutionScale: '1', scalingFilter: 'Bilinear', widenMode: 'experimental' };
      const profile = JSON.parse(result.getString(0)) as DisplayProfile;
      if (['1', '1.5', '2'].indexOf(profile.resolutionScale) < 0 ||
          ['Bilinear', 'Nearest'].indexOf(profile.scalingFilter) < 0 ||
          ['off', 'experimental'].indexOf(profile.widenMode) < 0) throw new Error('游戏设置格式无效');
      return profile;
    } finally { result.close(); }
  }

  async saveProfile(key: string, profile: DisplayProfile): Promise<void> {
    if (!this.database) throw new Error('游戏设置未就绪');
    await this.database.executeSql('INSERT OR REPLACE INTO PlayProfile (gameKey, payload, updatedAt) VALUES (?, ?, ?)',
      [key, JSON.stringify(profile), Date.now()]);
  }
}
