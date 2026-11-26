import { UIAbility, Want, AbilityConstant, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import engine from 'libs2aprobehost.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { stopTouchFeedback } from '../controls/TouchFeedback';
import { installCrashWatcher } from '../controls/Diagnostics';
import { bindStrings } from '../ui/Strings';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    bindStrings(this.context.resourceManager);
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    installCrashWatcher(this.context.filesDir);
    this.acceptLaunch(want);
  }
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void { this.acceptLaunch(want); }
  private acceptLaunch(want: Want): void {
    const id = want.parameters?.['s2armLaunchId'];
    const key = want.parameters?.['s2armGameKey'];
    if (typeof id !== 'string' || typeof key !== 'string' ||
        !/^[a-z0-9][a-z0-9-]{7,63}$/.test(id) || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(key)) return;
    const root = this.context.filesDir;
    const request = root + '/launch-requests/launch-request-' + id + '.json';
    const result = root + '/launch-results/launch-result-' + id + '.json';
    try {
      if (!fs.accessSync(root + '/launch-requests')) fs.mkdirSync(root + '/launch-requests');
      if (!fs.accessSync(root + '/launch-results')) fs.mkdirSync(root + '/launch-results');
      // Never overwrite an ID: retries can observe its result but cannot start another session.
      if (!fs.accessSync(result) && !fs.accessSync(request)) {
        const file = fs.openSync(request + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { fs.writeSync(file.fd, JSON.stringify({ requestId: id, key: key })); }
        finally { fs.closeSync(file); }
        fs.renameSync(request + '.tmp', request);
      }
      AppStorage.setOrCreate<number>('s2armLaunchVersion', (AppStorage.get<number>('s2armLaunchVersion') ?? 0) + 1);
    } catch (error) { console.error('S2Arm launch request could not be persisted'); }
  }
  private mainWindow: window.Window | undefined;
  private focusChanged = (event: window.WindowEventType): void => {
    if (event === window.WindowEventType.WINDOW_ACTIVE) {
      AppStorage.setOrCreate<boolean>('s2armFocused', true);
      engine.inputBlocked(AppStorage.get<boolean>('s2armOverlayInputBlocked') ?? false);
    } else if (event === window.WindowEventType.WINDOW_INACTIVE || event === window.WindowEventType.WINDOW_HIDDEN) {
      AppStorage.setOrCreate<boolean>('s2armFocused', false);
      engine.input(0, 0, 0, 0, 0); engine.inputBlocked(true);
      engine.stopFeedback(); stopTouchFeedback();
    }
  };
  onWindowStageCreate(stage: window.WindowStage): void {
    AppStorage.setOrCreate<boolean>('s2armForeground', true);
    AppStorage.setOrCreate<boolean>('s2armFocused', true);
    AppStorage.setOrCreate<boolean>('s2armOverlayInputBlocked', false);
    this.mainWindow = stage.getMainWindowSync();
    this.mainWindow.on('windowEvent', this.focusChanged);
    this.mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
    this.mainWindow.setWindowLayoutFullScreen(true);
    this.mainWindow.setWindowSystemBarEnable([]);
    stage.loadContent('pages/Index');
  }
  onForeground(): void {
    AppStorage.setOrCreate<boolean>('s2armForeground', true);
    engine.foreground(true);
    if (AppStorage.get<boolean>('s2armPlaying')) this.mainWindow?.setWindowKeepScreenOn(true);
  }
  onBackground(): void {
    AppStorage.setOrCreate<boolean>('s2armForeground', false);
    AppStorage.setOrCreate<boolean>('s2armFocused', false);
    engine.inputBlocked(true); engine.stopFeedback(); stopTouchFeedback();
    engine.foreground(false);
    this.mainWindow?.setWindowKeepScreenOn(false);
  }
  onWindowStageDestroy(): void {
    this.mainWindow?.off('windowEvent', this.focusChanged);
    engine.inputBlocked(true); engine.stopFeedback(); stopTouchFeedback();
    this.mainWindow = undefined;
  }
}
