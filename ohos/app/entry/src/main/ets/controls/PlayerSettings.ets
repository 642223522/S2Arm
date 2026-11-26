import { fileIo as fs } from '@kit.CoreFileKit';

export interface PlayerSettings {
  schema: string;
  touchFeedback: boolean;
  gameFeedback: boolean;
  hideTouchWithController: boolean;
  lastGame: string;
  showFps?: boolean;
  powerSave?: boolean;
  onboardingComplete?: boolean;
}

export function defaultPlayerSettings(): PlayerSettings {
  return { schema: 's2a.ohos.player-settings.v1', touchFeedback: false,
    gameFeedback: false, hideTouchWithController: true, lastGame: '' };
}

export function loadPlayerSettings(files: string): PlayerSettings {
  const fallback = defaultPlayerSettings();
  try {
    const path = files + '/player-settings.json';
    if (!fs.accessSync(path) || fs.statSync(path).size > 16384) return fallback;
    const value = JSON.parse(fs.readTextSync(path)) as PlayerSettings;
    if (value.schema !== fallback.schema || typeof value.touchFeedback !== 'boolean' ||
        typeof value.gameFeedback !== 'boolean' || typeof value.hideTouchWithController !== 'boolean' ||
        typeof value.lastGame !== 'string' || (value.showFps !== undefined && typeof value.showFps !== 'boolean') || (value.lastGame !== '' && !/^[a-z0-9][a-z0-9-]{0,63}$/.test(value.lastGame))) {
      return fallback;
    }
    return value;
  } catch (error) { return fallback; }
}

export function savePlayerSettings(files: string, value: PlayerSettings): boolean {
  try {
    const path = files + '/player-settings.json';
    const file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, JSON.stringify(value)); fs.fsyncSync(file.fd); }
    finally { fs.closeSync(file); }
    fs.renameSync(path + '.tmp', path);
    return true;
  } catch (error) { return false; }
}
