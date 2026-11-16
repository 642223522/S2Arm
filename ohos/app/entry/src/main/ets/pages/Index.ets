import { LauncherStore, DisplayProfile } from '../controls/LauncherStore';
import { LauncherShell } from '../ui/LauncherShell';
import { Game } from '../ui/LibraryModel';
import { Tokens } from '../ui/DesignTokens';
import { Glass, IMMERSIVE } from '../ui/Theme';
import { bundleManager } from '@kit.AbilityKit';
import engine from 'libs2aprobehost.so';
import { TouchDeck } from '../controls/TouchDeck';
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PlayerSettings, loadPlayerSettings, defaultPlayerSettings } from '../controls/PlayerSettings';
import { touchFeedbackSupported, touchPulse, stopTouchFeedback } from '../controls/TouchFeedback';
import { importGamePackage, graphicsMode, keepOriginalAspect, allowTallScreen, setGraphicsMode, ImportProgress, ImportResult } from '../controls/TarImport';
import { picker } from '@kit.CoreFileKit';
import { markSessionStart, markSessionEnd, takeUnfinishedSession, lastFailureLines, exportReport, SessionInfo } from '../controls/Diagnostics';

interface KeyboardRequest {
  version: number;
  type: string;
  header: string;
  subtitle: string;
  guide: string;
  initialText: string;
  submitText: string;
  minLength: number;
  maxLength: number;
  keyboardMode: number;
}

interface LaunchRequest { requestId: string; key: string; }
interface LaunchResult { requestId: string; key: string; status: string; message: string; }

interface PendingImport { key: string; directory: string; }

interface PreparedPatch { kind?: string; fps?: number | string; aspect?: string; }
interface PreparedGame {
  name?: string;
  displayName?: string;
  titleId: string;
  version: string;
  modules: string[];
  moduleDirectory?: string;
  patches?: PreparedPatch[];
  presentationAspect?: string;
  accent?: string;
}


// Plex/Emby-style capability badges: what this package actually carries, nothing promotional.
class Badge {
  text: string; strong: boolean;
  constructor(text: string, strong: boolean) { this.text = text; this.strong = strong; }
}
const BG: string = Tokens.background;
const PANEL: string = Tokens.surface;
const INK: string = Tokens.text;
const MUTED: string = Tokens.secondary;
const FAINT: string = '#5E636D';
const ACCENT: string = Tokens.accent;
const DARK_INK: string = '#0B0C0F';
// Accent is supplied by imported metadata; otherwise use the shared neutral.
function accentFor(titleId: string, declared?: string): string {
  if (declared !== undefined && /^#[0-9A-Fa-f]{6}$/.test(declared)) return declared;
  return '#B8C4FF';
}

@Entry
@Component
struct Index {
  @State games: Game[] = [];
  @State storeReady: boolean = false;
  @State profileBusy: boolean = true;
  @State profileError: string = '';
  @State firstFrame: boolean = false;
  @State welcome: boolean = false;
  @State welcomeStep: number = 0;
  @State launchFailed: boolean = false;
  private launchStarted: number = 0;
  private presentBaseline: number = 0;
  private profileRequest: number = 0;
  private indexRequest: number = 0;
  private store: LauncherStore = new LauncherStore();
  @State pageHeight: number = 400;
  @State editPreview: boolean = false;
  @State importGuide: boolean = false;
  @State importing: boolean = false;
  @State importStatus: string = '';
  @State gfxMode: string = 'generic';
  @State gfxDirectAvailable: boolean = false;
  @State selected: number = 0;
  @State playing: boolean = false;
  @State controls: boolean = true;
  @State message: string = '';
  @State ready: boolean = false;
  @State resolutionScale: string = '1';
  @State scalingFilter: string = 'Bilinear';
  @State displaySettingsVisible: boolean = false;
  @State widenMode: string = 'experimental';
  @State leftX: number = 0;
  @State leftY: number = 0;
  @State rightX: number = 0;
  @State rightY: number = 0;
  @State keyboardVisible: boolean = false;
  @State keyboardText: string = '';
  @State keyboardHeader: string = '';
  @State keyboardSubtitle: string = '';
  @State keyboardGuide: string = '';
  @State keyboardSubmit: string = '';
  @State keyboardMin: number = 0;
  @State keyboardMax: number = 100;
  @State keyboardMode: number = 0;
  @State keyboardError: string = '';
  @State gameMenu: boolean = false;
  @State exitConfirm: boolean = false;
  @State returning: boolean = false;
  @State playerSettingsVisible: boolean = false;
  @State touchEditing: boolean = false;
  @State editControlsOnOpen: boolean = false;
  @State touchFeedback: boolean = false;
  @State gameFeedback: boolean = false;
  @State powerSave: boolean = false;
  @State hideTouchWithController: boolean = true;
  @State controllerConnected: boolean = false;
  @State controllerAvailable: boolean = false;
  @State controllerName: string = '';
  @State controllerDetail: string = '连接蓝牙或 USB 手柄后，在这里查看状态。';
  @State feedbackMessage: string = '';
  @State menuError: string = '';
  @State touchFeedbackAvailable: boolean = false;
  @State badges: Badge[] = [];
  @State accent: string = '#B8C4FF';
  @State showFps: boolean = false;
  @State fpsText: string = '';
  @State crashTitle: string = '';
  @State crashLines: string[] = [];
  @State diagnosticsVisible: boolean = false;
  @State diagnosticsStatus: string = '';
  private fpsLastCount: number = -1;
  private fpsLastTime: number = 0;
  private player: PlayerSettings = defaultPlayerSettings();
  private statusTick: number = 0;
  private keyboardId: string = '';
  private buttons: number = 0;
  private files: string = '';
  private preparedModules: string = '';
  private moduleDirectory: string = 'ohos';
  private poller: number = -1;
  private launchVersion: number = -1;
  private activeLaunch: LaunchRequest | undefined;


  aboutToAppear() {
    this.files = (getContext(this) as common.UIAbilityContext).filesDir;
    this.player = loadPlayerSettings(this.files);
    this.touchFeedback = this.player.touchFeedback;
    this.gameFeedback = this.player.gameFeedback;
    this.powerSave = this.player.powerSave === true;
    this.hideTouchWithController = this.player.hideTouchWithController;
    this.showFps = this.player.showFps === true;
    const unfinished: SessionInfo | undefined = takeUnfinishedSession(this.files);
    if (unfinished !== undefined) {
      this.crashTitle = unfinished.title + (unfinished.mode === 'direct' ? ' · 直连' : ' · 兼容');
      this.crashLines = lastFailureLines(this.files, 4);
    }
    AppStorage.setOrCreate<boolean>('s2armTouchFeedback', this.touchFeedback);
    this.touchFeedbackAvailable = touchFeedbackSupported();
    this.feedbackMessage = engine.gameFeedback(this.gameFeedback);
    this.initializeStore();
    this.pollController();
    this.poller = setInterval(() => {
      this.pollLaunchRequests();
      if ((this.statusTick++ % 4) === 0 && AppStorage.get<boolean>('s2armForeground')) this.pollController();
      if (!this.playing) return;
      this.pollKeyboard();
      if (this.showFps) this.sampleFps();
      const s = engine.status();
      if (this.playing && !this.firstFrame && !this.launchFailed) {
        if (engine.presentCount() > this.presentBaseline) {
          this.firstFrame = true; this.syncInputGate();
          this.store.markFirstFrame(this.games[this.selected].titleId).catch(() => {
            console.warn('S2Arm recent-game timestamp was not saved');
          });
        }
        else if (s.error !== 0 || s.finished || Date.now() - this.launchStarted > 60000) this.launchFailed = true;
      }
      if (this.activeLaunch) {
        if (s.error !== 0 || s.finished || s.detail.startsWith('会话停止请求')) {
          this.writeLaunchResult(this.activeLaunch, 'failed', s.detail + ' · ' + s.error.toString());
          this.activeLaunch = undefined;
        } else if (s.state === 4) {
          this.writeLaunchResult(this.activeLaunch, 'runtime-started', '运行时已启动；未验证首帧或可玩性。');
          this.activeLaunch = undefined;
        }
      }
      if (s.error !== 0 || s.finished || s.detail.startsWith('会话停止请求')) {
        this.message = s.detail + ' · ' + s.error.toString();
      } else {
        const states: string[] = ['准备运行库', '加载模块', '内存已就绪', '图形与服务已就绪', '游戏运行中', '启动失败', '正在停止'];
        this.message = states[s.state] ?? '读取运行状态';
      }
    }, 250);
  }
  private async initializeStore(): Promise<void> {
    this.profileError = '';
    try {
      this.player = await this.store.open(getContext(this) as common.UIAbilityContext);
      this.touchFeedback = this.player.touchFeedback;
      this.gameFeedback = this.player.gameFeedback;
      this.powerSave = this.player.powerSave === true;
      this.hideTouchWithController = this.player.hideTouchWithController;
      this.showFps = this.player.showFps === true;
      AppStorage.setOrCreate<boolean>('s2armTouchFeedback', this.touchFeedback);
      engine.gameFeedback(this.gameFeedback);
      this.storeReady = true;
      this.loadGames();
      this.welcome = this.games.length === 0 && this.player.onboardingComplete !== true;
    } catch (error) {
      this.profileBusy = false;
      this.profileError = '无法读取设置，请重新打开应用';
      this.message = this.profileError;
    }
  }
  private async loadSelectedProfile(): Promise<void> {
    const game = this.games[this.selected];
    if (!game || !this.storeReady) { this.profileBusy = false; return; }
    const request = ++this.profileRequest;
    this.profileBusy = true; this.profileError = '';
    try {
      const profile = await this.store.loadProfile(game.key);
      if (request !== this.profileRequest) return;
      // 只走直连：分辨率、缩放、画幅不再给选项；宽屏由包内 presentationAspect 决定（有就宽屏，没有就原比例）。
      if (profile === undefined) return;
      this.checkGame();
    } catch (error) {
      if (request === this.profileRequest) this.profileError = '无法读取游戏设置';
    } finally { if (request === this.profileRequest) this.profileBusy = false; }
  }
  private async saveDisplay(): Promise<void> {
    const game = this.games[this.selected];
    if (!game || this.profileBusy) return;
    this.profileBusy = true; this.profileError = '';
    try {
      const profile: DisplayProfile = { resolutionScale: this.resolutionScale,
        scalingFilter: this.scalingFilter, widenMode: this.widenMode };
      await this.store.saveProfile(game.key, profile);
      this.displaySettingsVisible = false;
    } catch (error) { this.profileError = '未保存，请重试'; }
    finally { this.profileBusy = false; }
  }
  private async refreshGameIndex(found: Game[]): Promise<void> {
    const request = ++this.indexRequest;
    try {
      const indexed = await this.store.indexGames(found, this.files);
      if (request !== this.indexRequest || this.playing) return;
      const selectedKey = this.games[this.selected]?.key;
      this.games = indexed;
      this.selected = Math.max(0, indexed.findIndex((game: Game) => game.key === selectedKey));
    } catch (error) { this.message = '游戏索引未保存，请重新扫描'; }
  }
  private async toggleFavorite(): Promise<void> {
    const game = this.games[this.selected];
    if (!game) return;
    try {
      await this.store.setFavorite(game.titleId, !game.favorite);
      await this.refreshGameIndex(this.games);
    } catch (error) { this.message = '收藏未保存，请重试'; }
  }
  private async finishWelcome(): Promise<void> {
    this.player.onboardingComplete = true;
    try { await this.store.saveGlobals(this.player); this.welcome = false; }
    catch (error) { this.message = '未保存，请重试'; }
  }
  aboutToDisappear() {
    if (this.poller >= 0) clearInterval(this.poller);
    engine.input(0, 0, 0, 0, 0);
    engine.stopFeedback(); stopTouchFeedback();
    if (this.keyboardVisible) this.replyKeyboard(false);
  }
  onBackPress(): boolean {
    if (this.returning) return true;
    if (this.keyboardVisible) { this.replyKeyboard(false); return true; }
    if (this.exitConfirm) { this.exitConfirm = false; this.syncInputGate(); return true; }
    if (this.playerSettingsVisible) { this.closePlayerSettings(); return true; }
    if (this.editPreview) { this.editPreview = false; return true; }
    if (this.importGuide) { this.importGuide = false; return true; }
    if (this.diagnosticsVisible) { this.diagnosticsVisible = false; return true; }
    if (this.displaySettingsVisible) { this.saveDisplay(); return true; }
    if (this.touchEditing) return true;
    if (this.playing) { this.showGameMenu(!this.gameMenu); return true; }
    return false;
  }
  private syncInputGate(): void {
    const blocked = this.gameMenu || this.exitConfirm || this.returning || this.keyboardVisible ||
      this.touchEditing || (this.playing && !this.firstFrame) || (this.playing && this.playerSettingsVisible);
    AppStorage.setOrCreate<boolean>('s2armOverlayInputBlocked', blocked);
    engine.inputBlocked(blocked || !AppStorage.get<boolean>('s2armFocused'));
  }
  private showGameMenu(show: boolean): void {
    this.gameMenu = show; this.exitConfirm = false;
    engine.input(0, 0, 0, 0, 0);
    if (show) { engine.stopFeedback(); stopTouchFeedback(); }
    this.syncInputGate();
  }
  private pollController(): void {
    const status = engine.controllerStatus();
    const wasUsable = this.controllerAvailable && this.controllerConnected;
    this.controllerAvailable = status.available;
    this.controllerConnected = status.connected;
    this.controllerName = status.name;
    this.controllerDetail = status.detail;
    if (this.playing && this.hideTouchWithController && wasUsable !== (status.available && status.connected)) {
      engine.input(0, 0, 0, 0, 0);
      this.controls = !(status.available && status.connected);
    }
  }
  private persistPlayer(): void {
    this.player.touchFeedback = this.touchFeedback;
    this.player.gameFeedback = this.gameFeedback;
    this.player.powerSave = this.powerSave;
    this.player.hideTouchWithController = this.hideTouchWithController;
    this.player.showFps = this.showFps;
    this.store.saveGlobals(this.player).catch(() => { this.message = '设置未保存，请重试'; this.feedbackMessage = '设置未保存，请重试'; });
  }
  private closePlayerSettings(): void {
    this.playerSettingsVisible = false;
    if (this.playing) this.gameMenu = true;
    this.syncInputGate();
  }
  private async returnToLibrary(): Promise<void> {
    if (this.returning) return;
    this.returning = true;
    engine.input(0, 0, 0, 0, 0);
    engine.stopFeedback(); stopTouchFeedback(); this.syncInputGate();
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const currentWindow = await window.getLastWindow(context);
      await currentWindow.setWindowKeepScreenOn(false);
      markSessionEnd(this.files);
      // The runtime owns native guest threads for this process. Restart through the
      // platform instead of reusing them or calling stop() before the restart request.
      await context.restartApp({ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' });
    } catch (error) {
      console.error('S2Arm return to library failed: ' + String(error));
      this.returning = false; this.exitConfirm = false;
      this.menuError = '未能返回游戏库。请重试，或先回到游戏。';
      this.syncInputGate();
      window.getLastWindow(context).then((w: window.Window) => w.setWindowKeepScreenOn(true)).catch(() => {});
    }
  }
  private validKeyboardText(value: string, mode: number): boolean {
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF) {
        i++;
        if (i >= value.length || value.charCodeAt(i) < 0xDC00 || value.charCodeAt(i) > 0xDFFF) return false;
      } else if (code >= 0xDC00 && code <= 0xDFFF) return false;
    }
    if (mode === 1) return /^[0-9.]*$/.test(value);
    if (mode === 2) return /^[\x20-\x7E]*$/.test(value);
    return mode === 0 || mode === 3;
  }
  private pollKeyboard() {
    if (this.keyboardVisible) return;
    const pending = engine.uiTake();
    if (pending.error === -6 || pending.error === -4) return;
    if (pending.error !== 0 || !/^[1-9][0-9]{0,19}$/.test(pending.id)) {
      this.message = '无法读取游戏输入请求：' + pending.error.toString(); return;
    }
    try {
      const request = JSON.parse(pending.request) as KeyboardRequest;
      if (request.version !== 1 || request.type !== 'keyboard' ||
          typeof request.header !== 'string' || typeof request.subtitle !== 'string' ||
          typeof request.guide !== 'string' || typeof request.initialText !== 'string' ||
          typeof request.submitText !== 'string' || !Number.isInteger(request.minLength) ||
          !Number.isInteger(request.maxLength) || request.minLength < 0 ||
          request.maxLength < request.minLength || request.maxLength > 1000 ||
          request.initialText.length > request.maxLength ||
          !this.validKeyboardText(request.initialText, request.keyboardMode)) {
        engine.uiCancel(pending.id); this.message = '游戏输入请求格式或模式尚不受支持'; return;
      }
      this.keyboardId = pending.id;
      this.keyboardHeader = request.header;
      this.keyboardSubtitle = request.subtitle;
      this.keyboardGuide = request.guide;
      this.keyboardSubmit = request.submitText;
      this.keyboardMin = request.minLength;
      this.keyboardMax = request.maxLength;
      this.keyboardMode = request.keyboardMode;
      this.keyboardText = request.initialText;
      this.keyboardError = '';
      this.buttons = 0; this.leftX = 0; this.leftY = 0; this.rightX = 0; this.rightY = 0;
      this.send();
      this.keyboardVisible = true; this.syncInputGate();
    } catch (error) {
      engine.uiCancel(pending.id); this.message = '无法解析游戏输入请求';
    }
  }
  private replyKeyboard(accepted: boolean) {
    if (!this.keyboardVisible || this.keyboardId.length === 0) return;
    if (accepted && (this.keyboardText.length < this.keyboardMin || this.keyboardText.length > this.keyboardMax ||
        !this.validKeyboardText(this.keyboardText, this.keyboardMode))) {
      this.keyboardError = '请输入 ' + this.keyboardMin.toString() + ' 至 ' + this.keyboardMax.toString() + ' 个字符，并符合输入类型。';
      return;
    }
    const result = engine.uiReply(this.keyboardId, JSON.stringify({
      version: 1, type: 'keyboard', accepted: accepted, text: accepted ? this.keyboardText : ''
    }));
    this.keyboardVisible = false; this.keyboardId = ''; this.keyboardText = ''; this.syncInputGate();
    if (result !== 0) this.message = '输入请求已结束，未提交内容：' + result.toString();
  }
  @Builder keyboardDialog() {
    Column() {
      Column({ space: 10 }) {
        Text(this.keyboardHeader.length > 0 ? this.keyboardHeader : '输入文字').fontSize(21).fontWeight(FontWeight.Bold).fontColor(INK)
        if (this.keyboardSubtitle.length > 0) Text(this.keyboardSubtitle).fontSize(13).fontColor(MUTED)
        TextInput({ text: this.keyboardText, placeholder: this.keyboardGuide })
          .id('s2arm-keyboard-text').width('100%').height(48).fontSize(18)
          .backgroundColor(BG).fontColor(INK).caretColor(ACCENT)
          .type(InputType.Normal)
          .maxLength(this.keyboardMax).defaultFocus(true)
          .onChange((value: string) => { this.keyboardText = value; this.keyboardError = ''; })
          .onSubmit(() => this.replyKeyboard(true))
        if (this.keyboardError.length > 0) Text(this.keyboardError).fontSize(12).fontColor(ACCENT)
        Row({ space: 16 }) {
          Button('取消').id('s2arm-keyboard-cancel').backgroundColor(BG).fontColor(INK).onClick(() => this.replyKeyboard(false))
          Button(this.keyboardSubmit.length > 0 ? this.keyboardSubmit : '确定').id('s2arm-keyboard-submit')
            .backgroundColor(ACCENT).fontColor('#102334').onClick(() => this.replyKeyboard(true))
        }.justifyContent(FlexAlign.End).width('100%')
      }.width('70%').padding(18).backgroundColor(PANEL).borderRadius(18)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#BB080E1A')
  }
  private writeLaunchResult(request: LaunchRequest, status: string, message: string): void {
    const result: LaunchResult = { requestId: request.requestId, key: request.key, status: status, message: message };
    const path = this.files + '/launch-results/launch-result-' + request.requestId + '.json';
    const file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, JSON.stringify(result)); }
    finally { fs.closeSync(file); }
    fs.renameSync(path + '.tmp', path);
  }
  private async pollLaunchRequests(): Promise<void> {
    if (!this.storeReady) return;
    const version = AppStorage.get<number>('s2armLaunchVersion') ?? 0;
    if (version === this.launchVersion) return;
    this.launchVersion = version;
    try {
      const inbox = this.files + '/launch-requests';
      if (!fs.accessSync(inbox)) return;
      for (const name of fs.listFileSync(inbox, { recursion: false, listNum: 1024 })) {
        if (!/^launch-request-[a-z0-9][a-z0-9-]{7,63}\.json$/.test(name)) continue;
        const path = inbox + '/' + name;
        if (fs.statSync(path).size > 1024) continue;
        const request = JSON.parse(fs.readTextSync(path)) as LaunchRequest;
        if (typeof request.requestId !== 'string' || typeof request.key !== 'string' ||
            !/^[a-z0-9][a-z0-9-]{7,63}$/.test(request.requestId) || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(request.key) ||
            name !== 'launch-request-' + request.requestId + '.json') continue;
        if (fs.accessSync(this.files + '/launch-results/launch-result-' + request.requestId + '.json')) { fs.unlinkSync(path); continue; }
        // Persist acceptance BEFORE any side effect. A process interruption cannot replay this ID.
        this.writeLaunchResult(request, 'accepted', '请求已接收，正在核对导入和运行条件。');
        fs.unlinkSync(path); // Only consume this validated request, never game data.
        if (this.playing || this.activeLaunch || AppStorage.get<boolean>('s2armPlaying')) {
          this.writeLaunchResult(request, 'busy', '已有游戏会话；未中断或切换游戏。'); continue;
        }
        this.loadGames(); // Finalizes pending imports before consulting ready.json.
        const index = this.games.findIndex((game: Game) => game.key === request.key);
        if (index < 0) { this.writeLaunchResult(request, 'not-ready', '游戏尚未完成导入。'); continue; }
        this.selected = index; this.checkGame();
        await this.loadSelectedProfile();
        if (!this.ready) { this.writeLaunchResult(request, 'not-ready', '游戏运行文件清单未就绪。'); continue; }
        try {
          this.start();
          if (!this.playing) { this.writeLaunchResult(request, 'failed', this.message); continue; }
          this.activeLaunch = request;
        } catch (error) { this.writeLaunchResult(request, 'failed', '启动请求失败；请查看应用日志。'); }
      }
    } catch (error) { this.message = '启动请求处理失败；请求记录已保留。'; }
  }
  private finishImports() {
    // HDC writes sandbox files as the debug shell; directory rename belongs to the app UID.
    // listNum 0 = no limit. files/ also holds one runtime log per session; with a cap, pending imports were never seen.
    for (const name of fs.listFileSync(this.files, { recursion: false, listNum: 0 })) {
      if (!/^pending-import-[a-z0-9-]+\.json$/.test(name)) continue;
      try {
        const path = this.files + '/' + name;
        const pending = JSON.parse(fs.readTextSync(path)) as PendingImport;
        if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(pending.key) ||
            !/^\.import-[a-z0-9-]+$/.test(pending.directory)) continue;
        const from = this.files + '/games/' + pending.directory;
        const to = this.files + '/games/' + pending.key;
        if (fs.accessSync(to)) continue;
        if (!fs.accessSync(from + '/ready.json')) continue;
        fs.renameSync(from, to);
        fs.renameSync(path, path + '.done');
      } catch (error) { this.message = '有一项导入尚未完成，资源已保留。'; }
    }
  }
  private loadGames() {
    this.finishImports();
    const found: Game[] = [];
    let invalid: number = 0;
    try {
      const root = this.files + '/games';
      if (fs.accessSync(root)) {
        const folders: string[] = fs.listFileSync(root, { recursion: false, listNum: 256 });
        folders.sort();
        folders.forEach((key: string) => {
          if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(key)) return;
          const path = root + '/' + key + '/ready.json';
          try {
            if (!fs.accessSync(path)) return;
            if (fs.statSync(path).size > 65536) { invalid++; return; }
            const prepared = JSON.parse(fs.readTextSync(path)) as PreparedGame;
            if (typeof prepared.titleId !== 'string' || !/^[0-9A-Fa-f]{16}$/.test(prepared.titleId) ||
                typeof prepared.version !== 'string' || prepared.version.length > 64) { invalid++; return; }
            const title: string = typeof prepared.name === 'string' && prepared.name.trim().length > 0
              ? prepared.name.trim().substring(0, 128) : prepared.titleId.toUpperCase();
            const subtitle: string = typeof prepared.displayName === 'string' && prepared.displayName.trim().length > 0
              ? prepared.displayName.trim().substring(0, 128) : '已导入游戏';
            found.push(new Game(key, title, subtitle, prepared.titleId.toUpperCase(), '', prepared.version));
          } catch (error) { invalid++; }
        });
      }
      this.games = found;
      if (this.storeReady) this.refreshGameIndex(found);
      this.selected = Math.max(0, found.findIndex((game: Game) => game.key === this.player.lastGame));
      if (found.length > 0) { this.checkGame(); this.loadSelectedProfile(); }
      else { this.ready = false; this.message = ''; }
      if (invalid > 0) this.message += ' 有 ' + invalid.toString() + ' 项导入记录无效，已阻止加载。';
    } catch (error) {
      this.games = []; this.ready = false; this.message = '暂时无法读取游戏库。';
    }
  }
  private checkGame() {
    this.ready = false;
    if (this.selected >= this.games.length) return;
    const game = this.games[this.selected];
    this.preparedModules = '';
    let prepared: PreparedGame | undefined = undefined;
    try {
      const path = this.files + '/games/' + game.key + '/ready.json';
      if (fs.accessSync(path)) {
        prepared = JSON.parse(fs.readTextSync(path)) as PreparedGame;
        const modules = prepared.modules;
        const directory = prepared.moduleDirectory ?? 'ohos';
        if (prepared.titleId.toUpperCase() === game.titleId && Array.isArray(modules) && modules.length > 0 &&
            modules.length <= 16 && modules[0] === 'main' && /^[a-z][a-z0-9-]*$/.test(directory)) {
          let valid = true;
          modules.forEach((name: string, index: number) => {
            if (typeof name !== 'string' || !/^[A-Za-z0-9_]{1,15}$/.test(name) || modules.indexOf(name) !== index) valid = false;
          });
          if (valid) {
            this.preparedModules = modules.join(',');
            this.moduleDirectory = directory;
            this.ready = true;
          }
        }
      }
    } catch (error) { this.ready = false; }
    this.gfxMode = graphicsMode(this.files, game.titleId);
    this.gfxDirectAvailable = this.ready && fs.accessSync(this.files + '/games/' + game.key + '/' + this.moduleDirectory + '/graphics.v1.json');
    if (this.ready && !this.gfxDirectAvailable) { this.ready = false; this.message = '这个游戏包没有直连图形库，请用新版打包工具重新出包。'; }
    else this.message = this.ready ? '' : '游戏文件不完整，请重新导入游戏包。';
    this.accent = accentFor(game.titleId, prepared?.accent);
    this.refreshBadges(prepared);
  }
  private refreshBadges(prepared?: PreparedGame): void {
    const list: Badge[] = [];
    // NVN is the Switch graphics API every descriptor-carrying package was prepared from.
    if (this.gfxDirectAvailable) list.push(new Badge('NVN', false));
    const patches: PreparedPatch[] = prepared?.patches ?? [];
    if (patches.some((p: PreparedPatch) => p.kind === 'fps' && Number(p.fps) >= 60)) list.push(new Badge('60 FPS', true));
    const aspect = prepared?.presentationAspect;
    if (typeof aspect === 'string' && /^[0-9]{1,5}:[0-9]{1,5}$/.test(aspect)) list.push(new Badge('宽屏 ' + aspect, true));
    if (this.resolutionScale !== '1') list.push(new Badge(this.resolutionScale + '× 分辨率', false));
    this.badges = list;
  }
  private setGfx(mode: string) {
    if (this.selected >= this.games.length) return;
    try { setGraphicsMode(this.files, this.games[this.selected].titleId, mode); this.gfxMode = mode; this.checkGame(); }
    catch (error) { this.message = '图形模式没有保存'; }
  }
  private async pickAndImport() {
    if (this.importing) return;
    let uris: string[] = [];
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 32;   // a large package comes as name.tar.001, .002, ...: select all parts together
      uris = await new picker.DocumentViewPicker(getContext(this)).select(options);
      if (uris.length === 0) return;
    } catch (error) { this.importStatus = '无法打开文件选择'; return; }
    this.importing = true; this.importStatus = '正在读取游戏包…';
    const win = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
    win.setWindowKeepScreenOn(true).catch(() => {});
    try {
      const result: ImportResult = await importGamePackage(uris, this.files, (p: ImportProgress) => {
        this.importStatus = '正在导入 ' + (p.bytes / 1073741824).toFixed(1) + ' / ' + (p.total / 1073741824).toFixed(1) +
          ' GB';
      });
      this.importStatus = '已导入 · ' + result.files.toString() + ' 个文件';
      this.loadGames();
    } catch (error) {
      this.importStatus = '导入失败：' + ((error as Error).message ?? String(error));
    } finally {
      this.importing = false;
      win.setWindowKeepScreenOn(false).catch(() => {});
    }
  }
  private start() {
    if (this.profileBusy || !this.storeReady || this.profileError.length > 0 || this.playing || AppStorage.get<boolean>('s2armPlaying') || !this.ready || this.selected >= this.games.length) return;
    engine.powerSave(this.powerSave);
    engine.allowTall(this.selected < this.games.length && allowTallScreen(this.games[this.selected].titleId));
    const settingError = engine.displaySettings('1', 'Bilinear', 'off');
    if (settingError.length > 0) { this.message = settingError; return; }
    const error = engine.configure(i18n.System.getSystemLanguage(), i18n.System.getSystemRegion(),
      i18n.getTimeZone().getID(), display.getDefaultDisplaySync().refreshRate, this.files);
    if (error.length > 0) { this.message = error; return; }
    const game = this.games[this.selected];
    const root = this.files + '/games/' + game.key;
    const state = this.files + '/states/' + game.titleId;
    try {
      if (!fs.accessSync(state)) fs.mkdirSync(state, true);
      if (!fs.statSync(state).isDirectory()) {
        this.message = '游戏存档路径不是目录'; return;
      }
    } catch (error) { this.message = '无法打开游戏存档目录'; return; }
    // 引擎只读 graphics_mode 文件：推荐模式也要落盘。
    try { setGraphicsMode(this.files, game.titleId, this.gfxMode); } catch (error) { this.message = '无法写入图形模式'; return; }
    this.presentBaseline = Math.max(0, engine.presentCount());
    const result = engine.start(root + '/game', state, root + '/' + this.moduleDirectory, this.preparedModules, game.titleId);
    if (result.length > 0) { this.message = result; return; }
    this.player.lastGame = game.key; this.persistPlayer();
    markSessionStart(this.files, { key: game.key, title: game.title, titleId: game.titleId, mode: this.gfxMode, started: Date.now() });
    this.crashTitle = ''; this.crashLines = [];
    this.controls = !(this.controllerAvailable && this.controllerConnected) || !this.hideTouchWithController;
    this.firstFrame = false; this.launchFailed = false; this.launchStarted = Date.now();
    this.playing = true; this.gameMenu = false; this.returning = false;
    this.syncInputGate();
    AppStorage.setOrCreate<boolean>('s2armPlaying', true);
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((w: window.Window) => { w.setPreferredOrientation(window.Orientation.LANDSCAPE); w.setWindowKeepScreenOn(true); }).catch(() => {});
  }
  // Frames actually presented to the window per wall-clock second (not the game's internal target).
  private sampleFps(): void {
    const now = Date.now();
    if (now - this.fpsLastTime < 1000) return;
    const count = engine.presentCount();
    if (count < 0) { this.fpsText = ''; return; }
    if (this.fpsLastCount >= 0 && now > this.fpsLastTime) {
      this.fpsText = Math.round((count - this.fpsLastCount) * 1000 / (now - this.fpsLastTime)).toString();
    }
    this.fpsLastCount = count; this.fpsLastTime = now;
  }
  private appVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return 'S2Arm ' + info.versionName;
    } catch (error) { return ''; }
  }
  private displayLabel(): string {
    return this.resolutionScale + '× · ' + (this.scalingFilter === 'Nearest' ? '锐利' : '平滑');
  }
  private toast(text: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: text, duration: 1500 }); } catch (error) {}
  }
  private async exportDiagnostics(): Promise<void> {
    this.diagnosticsStatus = '正在整理日志…';
    try {
      const name = await exportReport(getContext(this) as common.UIAbilityContext, this.files, this.appVersion());
      this.diagnosticsStatus = name.length > 0 ? '已保存：' + name + '。把这个文件发给开发者即可。' : '';
    } catch (error) { this.diagnosticsStatus = '没能保存：' + ((error as Error).message ?? String(error)); }
  }
  private send() { engine.input(this.buttons, this.leftX, this.leftY, this.rightX, this.rightY); }
  private tint(alpha: string): string { return '#' + alpha + this.accent.substring(1); }
  @Builder badge(b: Badge) {
    Text(b.text).fontSize(10).fontWeight(b.strong ? FontWeight.Medium : FontWeight.Regular).letterSpacing(1.1)
      .fontColor(b.strong ? this.accent : '#C3C7CF').height(22).padding({ left: 8, right: 8 })
      .borderRadius(5).border({ width: 1, color: b.strong ? this.tint('80') : '#3A3E46' })
      .backgroundColor(b.strong ? this.tint('14') : '#0DFFFFFF')
  }
  @Builder option(label: string, active: boolean, action: () => void) {
    Text(label).fontSize(13).fontColor(active ? DARK_INK : '#D6D9DF').fontWeight(active ? FontWeight.Medium : FontWeight.Regular)
      .height(44).padding({ left: 14, right: 14 }).borderRadius(16)
      .backgroundColor(active ? ACCENT : '#14FFFFFF').onClick(action)
  }
  @Builder settingRow(label: string, hint: string) {
    Column({ space: 2 }) {
      Text(label).fontSize(14).fontColor(INK)
      if (hint.length > 0) Text(hint).fontSize(11).fontColor(FAINT).maxLines(2)
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }
  @Builder sheet(title: string) {
    Row() {
      Text(title).fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK)
      Blank()
    }.width('100%').margin({ bottom: 4 })
  }
  @Builder displaySettingsDialog() {
    Scroll() {
      Column({ space: 16 }) {
        this.sheet('画面')
        if (this.profileError.length > 0) Text(this.profileError).fontSize(14).fontColor('#FFB4A8')
        Row({ space: 8 }) {
          this.settingRow('分辨率', '')
          ForEach(['1', '1.5', '2'], (value: string) => {
            this.option(value + '×', this.resolutionScale === value, () => { this.resolutionScale = value; this.checkGame(); this.toast('下次启动生效'); })
          }, (value: string) => value)
        }.width('100%')
        Row({ space: 8 }) {
          this.settingRow('缩放', '')
          this.option('平滑', this.scalingFilter === 'Bilinear', () => { this.scalingFilter = 'Bilinear'; })
          this.option('锐利', this.scalingFilter === 'Nearest', () => { this.scalingFilter = 'Nearest'; })
        }.width('100%')
        if (!this.badges.some((b: Badge) => b.text.startsWith('宽屏'))) {
          Row({ space: 8 }) {
            this.settingRow('画幅', '')
            this.option('原始', this.widenMode === 'off', () => { this.widenMode = 'off'; })
            this.option('扩展', this.widenMode === 'experimental', () => { this.widenMode = 'experimental'; })
          }.width('100%')
        }
        if (this.gfxDirectAvailable) {
          Row({ space: 8 }) {
            this.settingRow('图形', '')
            this.option('兼容', this.gfxMode === 'generic', () => { this.setGfx('generic'); })
            this.option('直连', this.gfxMode === 'direct', () => { this.setGfx('direct'); })
          }.width('100%')
        }
        Row({ space: 8 }) {
          this.settingRow('显示帧率', '')
          Toggle({ type: ToggleType.Switch, isOn: this.showFps }).selectedColor(this.accent)
            .onChange((value: boolean) => { this.showFps = value; this.fpsText = ''; this.fpsLastCount = -1; this.persistPlayer(); })
        }.width('100%')
        Row() {
          Blank()
          Text('完成').fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK).height(48).padding({ left: 22, right: 22 })
            .borderRadius(18).backgroundColor(ACCENT).enabled(!this.profileBusy).onClick(() => { this.saveDisplay(); })
        }.width('100%').margin({ top: 4 })
      }.width('100%').padding({ left: 26, right: 26, top: 22, bottom: 20 })
    }.width('100%').height('100%')
  }
  private cover(game: Game): string { return 'file://' + this.files + '/games/' + game.key + '/game/icon.jpg'; }
  private hasCover(game: Game): boolean { return fs.accessSync(this.files + '/games/' + game.key + '/game/icon.jpg'); }
  @Builder pill(label: string, id: string, action: () => void) {
    Text(label).id(id).fontSize(12).fontColor('#D9DCE2').height(44).padding({ left: 14, right: 14 }).borderRadius(15)
      .backgroundColor('#14FFFFFF').border({ width: 1, color: '#1FFFFFFF' }).onClick(action)
  }
  @Builder primary(label: string, id: string, action: () => void) {
    Text(label).id(id).fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK).height(48)
      .padding({ left: 20, right: 20 }).borderRadius(18).backgroundColor(ACCENT).onClick(action)
  }
  @Builder library() {
    LauncherShell({ games: this.games, selected: this.selected, ready: this.ready && !this.profileBusy && this.profileError.length === 0,
      message: this.profileError || this.message, crashTitle: this.crashTitle, filesDir: this.files,
      lastGame: this.player.lastGame, controller: this.controllerConnected ? this.controllerName : '',
      loading: false, displayValue: this.displayLabel(), touchValue: '', version: this.appVersion(),
      onSelect: (key: string) => {
        const index = this.games.findIndex((game: Game) => game.key === key);
        if (index >= 0 && index !== this.selected) { this.selected = index; this.checkGame(); this.loadSelectedProfile(); }
      }, onStart: (): void => { this.start(); }, onImport: () => this.importGuide = true,
      onSettings: () => this.playerSettingsVisible = true,
      onDisplay: () => this.displaySettingsVisible = true,
      onControls: () => this.editPreview = true,
      onDiagnostics: () => this.diagnosticsVisible = true,
      onFavorite: () => this.toggleFavorite() })
  }
  @Builder importDialog() {
    Column({ space: 14 }) {
      this.sheet('导入游戏')
      Text('分卷请一次选全')
        .fontSize(13).fontColor(MUTED).lineHeight(21)
      if (this.importStatus.length > 0) Text(this.importStatus).fontSize(13).fontColor(this.accent).lineHeight(20)
      Row({ space: 10 }) {
        Blank()
        this.pill('重新扫描', 's2arm-rescan', () => { if (!this.importing) { this.loadGames(); this.importGuide = false; } })
        this.pill('关闭', 's2arm-import-close', () => { if (!this.importing) this.importGuide = false; })
        this.primary(this.importing ? '导入中…' : '选择游戏包', 's2arm-import-tar', () => { this.pickAndImport(); })
      }.width('100%').margin({ top: 4 })
    }.padding({ left: 26, right: 26, top: 22, bottom: 20 }).width('100%')
  }
  @Builder diagnosticsDialog() {
    Column({ space: 12 }) {
      this.sheet('运行诊断')
      if (this.crashTitle.length > 0) Text('上次 ' + this.crashTitle + ' 没有正常结束。').fontSize(13).fontColor('#FFB4A8')
      if (this.crashLines.length > 0) {
        Column({ space: 4 }) {
          ForEach(this.crashLines, (line: string) => {
            Text(line).fontSize(11).fontColor('#C9CDD4').fontFamily('monospace').maxLines(3)
          }, (line: string, index: number) => index.toString())
        }.alignItems(HorizontalAlign.Start).width('100%').padding(12).borderRadius(12).backgroundColor('#0AFFFFFF')
      } else {
        Text('日志里没有找到明确的错误行；导出完整日志更有帮助。').fontSize(12).fontColor(MUTED)
      }
      if (this.diagnosticsStatus.length > 0) Text(this.diagnosticsStatus).fontSize(12).fontColor(this.accent)
      Row({ space: 10 }) {
        Blank()
        this.pill('关闭', 's2arm-diag-close', () => { this.diagnosticsVisible = false; this.diagnosticsStatus = ''; })
        this.primary('导出日志', 's2arm-diag-export', () => { this.exportDiagnostics(); })
      }.width('100%').margin({ top: 4 })
    }.padding({ left: 26, right: 26, top: 22, bottom: 20 }).width('100%')
  }
  @Builder playerSettingsDialog() {
    Column({ space: 14 }) {
      this.sheet('设置')
      if (/失败|未保存|无法/.test(this.feedbackMessage)) Text(this.feedbackMessage).fontSize(14).fontColor('#FFB4A8')
      Row({ space: 12 }) {
        Circle().width(8).height(8).fill(this.controllerAvailable && this.controllerConnected ? this.accent : '#4A4E56')
        Column({ space: 2 }) {
          Text(this.controllerConnected ? (this.controllerName || '手柄已连接') : '未连接手柄').fontSize(14).fontColor(INK)
          if (this.controllerConnected && this.controllerDetail.length > 0) Text(this.controllerDetail).fontSize(11).fontColor(FAINT).maxLines(2)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(12).borderRadius(14).backgroundColor('#0AFFFFFF')
      Row() {
        this.settingRow('连接手柄时隐藏触控', '')
        Toggle({ type: ToggleType.Switch, isOn: this.hideTouchWithController }).selectedColor(this.accent).onChange((value: boolean) => {
          this.hideTouchWithController = value;
          if (this.playing) this.controls = !value || !(this.controllerAvailable && this.controllerConnected);
          this.persistPlayer();
        })
      }.width('100%')
      Row() {
        this.settingRow('按键触感', this.touchFeedbackAvailable ? '' : '这台设备不支持')
        Toggle({ type: ToggleType.Switch, isOn: this.touchFeedback }).selectedColor(this.accent).enabled(this.touchFeedbackAvailable)
          .onChange((value: boolean) => {
            this.touchFeedback = value; AppStorage.setOrCreate<boolean>('s2armTouchFeedback', value); this.persistPlayer();
            if (value) touchPulse(true); else stopTouchFeedback();
          })
      }.width('100%')
      Row() {
        this.settingRow('游戏震动', '')
        Toggle({ type: ToggleType.Switch, isOn: this.gameFeedback }).selectedColor(this.accent).onChange((value: boolean) => {
          this.gameFeedback = value; this.feedbackMessage = engine.gameFeedback(value); this.persistPlayer(); if (!value) engine.stopFeedback();
        })
      }.width('100%')
      Row() {
        this.settingRow('省电 30 帧', '')
        Toggle({ type: ToggleType.Switch, isOn: this.powerSave }).selectedColor(this.accent).onChange((value: boolean) => { this.powerSave = value; this.persistPlayer(); this.toast('下次启动生效'); })
      }.width('100%')
      Row() {
        this.settingRow('显示帧率', '')
        Toggle({ type: ToggleType.Switch, isOn: this.showFps }).selectedColor(this.accent)
          .onChange((value: boolean) => { this.showFps = value; this.fpsText = ''; this.fpsLastCount = -1; this.persistPlayer(); })
      }.width('100%')
    }.width('100%').padding({ left: 26, right: 26, top: 22, bottom: 20 })
  }
  @Builder gameMenuDialog() {
    Column({ space: 12 }) {
      Text(this.games[this.selected].title).fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(1)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.badges, (b: Badge) => { Row() { this.badge(b) }.margin({ right: 6, bottom: 6 }) }, (b: Badge) => b.text)
      }.width('100%')
            Text('继续游戏').id('s2arm-resume').width('100%').height(42).textAlign(TextAlign.Center).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor(DARK_INK).borderRadius(21).backgroundColor(ACCENT)
        .onClick(() => { this.showGameMenu(false); })
      Row({ space: 10 }) {
        Text(this.controls ? '隐藏触控' : '显示触控').layoutWeight(1).height(36).textAlign(TextAlign.Center).fontSize(12)
          .fontColor(INK).borderRadius(18).backgroundColor('#14FFFFFF')
          .onClick(() => { this.controls = !this.controls; this.showGameMenu(false); })
        Text('设置').layoutWeight(1).height(36).textAlign(TextAlign.Center).fontSize(12)
          .fontColor(INK).borderRadius(18).backgroundColor('#14FFFFFF')
          .onClick(() => { this.gameMenu = false; this.playerSettingsVisible = true; this.syncInputGate(); })
      }.width('100%')
      Button('触控布局').height(44).width('100%').backgroundColor('#14FFFFFF').fontColor(INK)
        .onClick(() => { this.editControlsOnOpen = true; this.controls = true; this.showGameMenu(false); })
      Text('退出到游戏库').id('s2arm-return-library').width('100%').height(36).textAlign(TextAlign.Center).fontSize(12)
        .fontColor('#FFB4A8').borderRadius(18).backgroundColor('#1AFF7A6B')
        .onClick(() => { this.exitConfirm = true; this.syncInputGate(); })
      if (this.menuError.length > 0) Text(this.menuError).fontSize(11).fontColor('#FFB4A8')
    }.width('94%').constraintSize({ maxWidth: 520 }).padding(24).borderRadius(28)
      .backgroundColor(IMMERSIVE ? Color.Transparent : '#E616161C').systemMaterial(Glass.menu)

  }
  @Builder exitDialog() {
    Column({ space: 14 }) {
      Text(this.returning ? '正在返回游戏库' : '已经在游戏里存档了吗？').fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK)
      Text('退出会结束这次游戏，应用不会替游戏保存进度。').fontSize(13).fontColor(MUTED).lineHeight(21)
      Row({ space: 10 }) {
        Blank()
        Text('回去存档').id('s2arm-exit-cancel').height(38).padding({ left: 18, right: 18 }).fontSize(13).fontColor(INK)
          .borderRadius(19).backgroundColor('#14FFFFFF').enabled(!this.returning).onClick(() => { this.showGameMenu(false); })
        Text(this.returning ? '正在退出…' : '已存档，退出').id('s2arm-exit-confirm').height(38).padding({ left: 18, right: 18 })
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(DARK_INK).borderRadius(19).backgroundColor(ACCENT)
          .enabled(!this.returning).onClick(() => { this.returnToLibrary(); })
      }.width('100%')
    }.width('94%').constraintSize({ maxWidth: 520 }).padding(24).borderRadius(28)
      .backgroundColor(IMMERSIVE ? Color.Transparent : '#E616161C').systemMaterial(Glass.menu)

  }
  @Builder settingsSheet() {
    Scroll() { this.playerSettingsDialog() }.width('100%').height('100%')
  }
  @Builder diagnosticsSheet() {
    Scroll() { this.diagnosticsDialog() }.width('100%').height('100%')
  }
  @Builder importSheet() {
    Scroll() { this.importDialog() }.width('100%').height('100%')
  }
  @Builder welcomePage() {
    Column({ space: 24 }) {
      Text(['你的游戏，随身带', '导入游戏包', '选好操作，开玩'][this.welcomeStep])
        .fontSize(24).fontWeight(FontWeight.Medium).fontColor(INK)
      Text(['准备已生成的 S2Arm 游戏包', '分卷请一次选全', '触控与手柄都可用'][this.welcomeStep])
        .fontSize(16).fontColor(MUTED).maxLines(2)
      Text((this.welcomeStep + 1).toString() + ' / 3').fontSize(12).fontColor(MUTED)
      Button(this.welcomeStep < 2 ? '继续' : '进入游戏库').height(48).backgroundColor(ACCENT)
        .onClick(() => { if (this.welcomeStep < 2) this.welcomeStep++; else this.finishWelcome(); })
      Button('跳过').height(44).backgroundColor(PANEL).onClick(() => this.finishWelcome())
      if (this.message.length > 0) Text(this.message).fontSize(14).fontColor('#FFB4A8')
    }.padding(24).width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(BG)
  }
  build() {
    Stack() {
      XComponent({ id: 'game', type: XComponentType.SURFACE, libraryname: 's2aprobehost' }).width('100%').height('100%')
      if (!this.playing && this.storeReady) this.library()
      if (!this.storeReady) {
        Column({ space: 16 }) {
          if (this.profileError.length === 0) LoadingProgress().width(40).height(40).color(ACCENT)
          Text(this.profileError || '正在读取游戏库').fontSize(16).fontColor(INK)
          if (this.profileError.length > 0) Button('重试').height(48).onClick(() => this.initializeStore())
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(BG)
      }
      if (this.welcome && !this.playing) this.welcomePage()
      if (this.playing && this.firstFrame && this.controls && !this.keyboardVisible && !this.gameMenu && !this.playerSettingsVisible && !this.exitConfirm) {
        TouchDeck({gameId:this.games[this.selected].titleId,gameTitle:this.games[this.selected].title,filesDir:this.files,
          editOnOpen: this.editControlsOnOpen,
          onClose:()=>this.controls=false,onEditing:(value:boolean)=>{this.touchEditing=value;if(!value)this.editControlsOnOpen=false;this.syncInputGate();}})
      }
      if (this.playing && !this.keyboardVisible && !this.touchEditing && !this.gameMenu && !this.playerSettingsVisible) {
        Text('•••').id('s2arm-game-menu').fontSize(14).height(44).width(44).textAlign(TextAlign.Center).fontColor('#F5F5F7')
          .borderRadius(14).backgroundColor('#66101216').border({ width: 1, color: '#22FFFFFF' })
          .position({ x: 24, y: 10 }).accessibilityText('打开游戏菜单').onClick(() => { this.showGameMenu(true); })
      }
      if (this.playing && this.showFps && this.fpsText.length > 0) {
        Row({ space: 4 }) {
          Text(this.fpsText).fontSize(13).fontWeight(FontWeight.Medium).fontColor(INK).fontFamily('monospace')
          Text('FPS').fontSize(9).fontColor(MUTED).letterSpacing(1)
        }.height(24).padding({ left: 10, right: 10 }).borderRadius(12).backgroundColor('#80101216')
          .position({ x: '100%', y: 10 }).markAnchor({ x: '100%', y: 0 }).offset({ x: -20, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.playing && !this.firstFrame) {
        Column({ space: 16 }) {
          if (!this.launchFailed) LoadingProgress().width(40).height(40).color(ACCENT)
          Text(this.launchFailed ? '启动未完成' : '正在启动').fontSize(20).fontColor(INK)
          Text(this.message).fontSize(14).fontColor(MUTED).maxLines(3)
          if (this.launchFailed) Button('返回游戏库').height(48).backgroundColor(ACCENT).onClick(() => this.returnToLibrary())
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(24).backgroundColor(BG)
      }
      if (!this.playing && this.editPreview && this.games.length > 0) {
        TouchDeck({gameId:this.games[this.selected].titleId,gameTitle:this.games[this.selected].title,filesDir:this.files,preview:true,
          onClose:()=>this.editPreview=false,onEditing:(value:boolean)=>{this.touchEditing=value;this.syncInputGate();}})
      }

      if (this.gameMenu) Stack() { this.gameMenuDialog() }.width('100%').height('100%').backgroundColor('#44000000')
        .onClick(() => { this.showGameMenu(false); })

      if (this.exitConfirm) Stack() { this.exitDialog() }.width('100%').height('100%').backgroundColor('#AA000000')
      if (this.keyboardVisible) this.keyboardDialog()
      Column().width(0).height(0).bindSheet($$this.displaySettingsVisible, this.displaySettingsDialog, {
        height: SheetSize.MEDIUM, dragBar: true, backgroundColor: IMMERSIVE ? Color.Transparent : PANEL,
        systemMaterial: Glass.sheet,
        shouldDismiss: (action: SheetDismiss) => { this.saveDisplay(); action.dismiss(); }
      })
      Column().width(0).height(0).bindSheet($$this.diagnosticsVisible, this.diagnosticsSheet, {
        height: SheetSize.MEDIUM, dragBar: true, backgroundColor: IMMERSIVE ? Color.Transparent : PANEL,
        systemMaterial: Glass.sheet, onDisappear: () => { this.diagnosticsStatus = ''; }
      })
      Column().width(0).height(0).bindSheet($$this.playerSettingsVisible, this.settingsSheet, {
        height: SheetSize.LARGE, dragBar: true, backgroundColor: IMMERSIVE ? Color.Transparent : PANEL,
        systemMaterial: Glass.sheet,
        onDisappear: () => { this.closePlayerSettings(); }
      })
      Column().width(0).height(0).bindSheet($$this.importGuide, this.importSheet, {
        height: SheetSize.MEDIUM, dragBar: true, backgroundColor: IMMERSIVE ? Color.Transparent : PANEL,
        systemMaterial: Glass.sheet,
        shouldDismiss: (action: SheetDismiss) => { if (!this.importing) action.dismiss(); }
      })
    }.width('100%').height('100%').backgroundColor(BG)
      .onAreaChange((_old:Area,current:Area)=>this.pageHeight=Number(current.height))
  }
}
