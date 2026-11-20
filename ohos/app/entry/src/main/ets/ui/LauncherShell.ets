// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏库即首页（对齐 iOS ShellUI）：竖屏单列卡片 / 宽竖屏网格 / 横屏封面横排；
// 设置在顶栏齿轮，详情与设置走 Navigation。
import { C, R, L, M, Glass, IMMERSIVE } from './Theme';
import { Game, filterGames, sortGames } from './LibraryModel';
import { str } from './Strings';

const SORTS: string[] = ['recent', 'title', 'favorite'];
const SORT_LABELS: Resource[] = [$r('app.string.recent'), $r('app.string.sort_title'), $r('app.string.favorites')];

@Component
export struct LauncherShell {
  @Prop games: Game[] = [];
  @Prop selected: number = 0;
  @Prop ready: boolean = false;
  @Prop loading: boolean = false;
  @Prop message: string = '';
  @Prop crashTitle: string = '';
  @Prop lastGame: string = '';
  @Prop controller: string = '';
  @Prop displayValue: string = '';
  @Prop touchValue: string = '';
  @Prop version: string = '';
  filesDir: string = '';
  onSelect: (key: string) => void = () => {};
  onStart: () => void = () => {};
  onImport: () => void = () => {};
  onSettings: () => void = () => {};
  onDisplay: () => void = () => {};
  onControls: () => void = () => {};
  onDiagnostics: () => void = () => {};
  onFavorite: () => void = () => {};
  @State sortIndex: number = 0;
  @State query: string = '';
  @State pageWidth: number = 360;
  @State pageHeight: number = 720;
  private paths: NavPathStack = new NavPathStack();

  private current(): Game | undefined { return this.games[this.selected]; }
  private inset(): number { return this.pageWidth >= 600 ? 24 : 16; }
  private cover(game: Game): string { return 'file://' + this.filesDir + '/games/' + game.key + '/game/icon.jpg'; }
  // 横屏封面横排；竖屏够宽（平板、折叠屏展开）用网格；其余单列卡片。
  private layout(): string {
    if (this.pageWidth > this.pageHeight * 1.2) return 'covers';
    return this.pageWidth >= 600 ? 'grid' : 'column';
  }
  private coverWidth(): number { return Math.max(140, Math.min(280, this.pageHeight - 200)); }
  private shown(): Game[] { return sortGames(filterGames(this.games, this.query), SORTS[this.sortIndex]); }
  private open(game: Game): void {
    this.onSelect(game.key);
    this.paths.pushPath({ name: 'GameDetail' });
  }
  private startLabel(game: Game): string { return str(this.lastGame === game.key ? $r('app.string.continue') : $r('app.string.start')); }
  private startGameLabel(game: Game): Resource { return this.lastGame === game.key ? $r('app.string.resume_game') : $r('app.string.start_game'); }
  private columns(): string {
    const usable = this.pageWidth - this.inset() * 2 + 12;
    const count = Math.max(2, Math.min(6, Math.floor(usable / (L.gridMin + 12))));
    return Array.from<string>({ length: count }).fill('1fr').join(' ');
  }

  private hue(game: Game): string[] {
    const palettes: string[][] = [['#2B3A67', '#0F1426'], ['#1F4D45', '#0B1A17'], ['#5A2E46', '#1A0E16'],
      ['#4A3B1F', '#17120A'], ['#2E3F52', '#0D131A'], ['#3D2B5C', '#120D1C']];
    let h = 0;
    for (let i = 0; i < game.titleId.length; i++) h = (h * 31 + game.titleId.charCodeAt(i)) % 9973;
    return palettes[h % palettes.length];
  }
  @Builder artwork(game: Game) {
    Stack() {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 135, colors: [[this.hue(game)[0], 0], [this.hue(game)[1], 1]] })
      Text(game.title.split(' ').filter((w: string) => w.length > 0).slice(0, 2)
        .map((w: string) => w.substring(0, 1).toUpperCase()).join(''))
        .fontSize(44).fontWeight(FontWeight.Bold).fontColor('#33FFFFFF')
      Image(this.cover(game)).width('100%').height('100%').objectFit(ImageFit.Cover)
        .draggable(false).accessibilityText(game.title)
    }.width('100%').height('100%').backgroundColor(C.elevated2).hitTestBehavior(HitTestMode.None)
  }

  @Builder cardMenu(game: Game) {
    Menu() {
      MenuItem({ content: $r('app.string.start_game') }).enabled(this.ready).onClick(() => { this.onSelect(game.key); this.onStart(); })
      MenuItem({ content: game.favorite ? $r('app.string.unfavorite') : $r('app.string.favorite') }).onClick(() => { this.onSelect(game.key); this.onFavorite(); })
      MenuItem({ content: $r('app.string.touch_layout') }).onClick(() => { this.onSelect(game.key); this.onControls(); })
    }
  }

  @Builder playPill(game: Game, id: string) {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.play_fill')).fontSize(16).fontColor([C.inverse])
      Text(this.startLabel(game)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(C.inverse)
    }.id(id).height(L.cta).padding({ left: 20, right: 22 }).borderRadius(R.pill)
      .backgroundColor(this.ready ? C.primary : '#66F5F5F7')
      .onClick(() => { if (this.ready) { this.onSelect(game.key); this.onStart(); } })
      .accessibilityText(this.startLabel(game) + game.title).accessibilityGroup(true)
  }

  @Builder iconButton(symbol: Resource, label: Resource, id: string, action: () => void) {
    Stack() {
      SymbolGlyph(symbol).fontSize(20).fontColor([C.primary])
    }.id(id).width(L.target).height(L.target).borderRadius(R.pill)
      .backgroundColor(IMMERSIVE ? Color.Transparent : C.glassTint)
      .systemMaterial(Glass.chip)
      .onClick(action).accessibilityText(label)
  }

  @Builder ambient() {
    // 只模糊静态封面；游戏画面上不叠材质（§1.3.6-2）。
    Stack({ alignContent: Alignment.Top }) {
      if (this.current() !== undefined) {
        ForEach([this.current()!.key], (key: string) => {
          Image('file://' + this.filesDir + '/games/' + key + '/game/icon.jpg').width('100%').height('62%')
            .objectFit(ImageFit.Cover).blur(64).opacity(0.5)
            .transition(TransitionEffect.OPACITY.animation({ duration: M.slow, curve: Curve.Friction }))
        }, (key: string) => key)
      }
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#330B0B0F', 0.0], ['#CC0B0B0F', 0.42], [C.base, 0.62]] })
    }.width('100%').height('100%').backgroundColor(C.base).hitTestBehavior(HitTestMode.None)
  }

  @Builder header() {
    Row({ space: 8 }) {
      Text($r('app.string.library')).fontSize(28).fontWeight(FontWeight.Bold).fontColor(C.primary)
      Blank()
      this.iconButton($r('sys.symbol.folder_badge_plus'), $r('app.string.import_game'), 's2arm-import', this.onImport)
      this.iconButton($r('sys.symbol.gearshape'), $r('app.string.settings'), 's2arm-settings',
        () => { this.paths.pushPath({ name: 'Settings' }); })
    }.height(L.header).width('100%').padding({ left: this.inset(), right: this.inset() })
  }

  @Builder backBar(title: ResourceStr, id: string) {
    Row({ space: 8 }) {
      this.iconButton($r('sys.symbol.chevron_left'), $r('app.string.back'), id, () => { this.paths.pop(); })
      Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(C.primary)
    }.width('100%').height(L.header).padding({ left: this.inset() - 4 })
  }

  @Builder emptyState(title: ResourceStr, importable: boolean) {
    Column({ space: 20 }) {
      SymbolGlyph($r('sys.symbol.gamecontroller')).fontSize(56).fontColor([C.tertiary])
      Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(C.secondary)
      if (importable) {
        Text($r('app.string.import_game')).id('s2arm-import-first').fontSize(16).fontWeight(FontWeight.Medium).fontColor(C.inverse)
          .height(L.cta).padding({ left: 28, right: 28 }).borderRadius(R.pill).backgroundColor(C.primary)
          .onClick(this.onImport)
      } else {
        Text($r('app.string.clear_search')).fontSize(16).fontColor(C.primary).height(L.cta).padding({ left: 24, right: 24 })
          .borderRadius(R.pill).backgroundColor(C.elevated2).onClick(() => this.query = '')
      }
    }.width('100%').height(320).justifyContent(FlexAlign.Center)
  }

  @Builder skeleton() {
    Column({ space: 12 }) {
      ForEach([0, 1, 2], (i: number) => {
        Column().width('100%').height(L.card).borderRadius(R.lg).backgroundColor(C.elevated)
      }, (i: number) => i.toString())
    }.padding({ left: this.inset(), right: this.inset(), top: 8 })
  }

  // 竖屏单列：封面、名称、版本；当前选中的游戏右侧给开始/继续（其余游戏的设置要先读完才能启动），点卡片进详情。
  @Builder columnCard(game: Game) {
    Row({ space: 14 }) {
      Stack() { this.artwork(game) }.width(L.card - 24).height(L.card - 24).borderRadius(R.md).clip(true)
      Column({ space: 4 }) {
        Text(game.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(C.primary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (game.version.length > 0) Text(game.version).fontSize(13).fontColor(C.secondary).maxLines(1)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.current()?.key === game.key) {
        this.playPill(game, 's2arm-start')
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([C.tertiary])
      }
    }.width('100%').height(L.card).padding({ left: 12, right: 12 }).borderRadius(R.lg)
      .backgroundColor(this.current()?.key === game.key ? C.elevated2 : C.elevated)
      .onClick(() => this.open(game)).bindContextMenu(this.cardMenu(game), ResponseType.LongPress)
      .focusable(true).accessibilityText(str($r('app.string.game_details_a11y'), game.title))
  }

  // 横屏封面横排（无 iOS 的 3D 扇形）。
  @Builder coverCard(game: Game) {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.artwork(game)
        if (game.favorite) {
          SymbolGlyph($r('sys.symbol.star_fill')).fontSize(16).fontColor([C.primary]).margin(10)
        }
      }.width('100%').aspectRatio(1).borderRadius(R.xl).clip(true)
        .border({ width: 2, color: this.current()?.key === game.key ? C.primary : Color.Transparent })
      Text(game.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(C.primary)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }.width(this.coverWidth())
      .onClick(() => this.open(game)).bindContextMenu(this.cardMenu(game), ResponseType.LongPress)
      .focusable(true).accessibilityText(str($r('app.string.game_details_a11y'), game.title))
  }

  @Builder gridCard(game: Game) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.artwork(game)
        if (game.favorite) {
          SymbolGlyph($r('sys.symbol.star_fill')).fontSize(14).fontColor([C.primary]).margin(8)
        }
      }.width('100%').aspectRatio(1).borderRadius(R.lg).clip(true)
      Text(game.title).fontSize(14).fontColor(C.primary).maxLines(2).lineHeight(19)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).height(38).width('100%')
    }.onClick(() => this.open(game)).bindContextMenu(this.cardMenu(game), ResponseType.LongPress)
      .focusable(true).accessibilityText(game.title)
  }

  @Builder library() {
    Column({ space: 12 }) {
      this.header()
      Column({ space: 12 }) {
        if (this.crashTitle.length > 0 && this.games.length > 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([C.error])
            Text($r('app.string.last_run_interrupted')).fontSize(14).fontColor(C.error)
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([C.tertiary])
          }.width('100%').height(L.target).padding({ left: 16, right: 12 }).borderRadius(R.lg)
            .backgroundColor('#1AFF453A').onClick(this.onDiagnostics)
        }
        if (this.message.length > 0) Text(this.message).fontColor(C.error).fontSize(14).maxLines(3)
        Row({ space: 12 }) {
          Search({ value: this.query, placeholder: $r('app.string.search') }).height(44).layoutWeight(1)
            .backgroundColor(C.elevated).fontColor(C.primary).placeholderColor(C.tertiary)
            .onChange((value: string) => this.query = value)
          Select(SORT_LABELS.map((label: Resource): SelectOption => ({ value: label })))
            .selected(this.sortIndex).value(SORT_LABELS[this.sortIndex])
            .font({ size: 14 }).fontColor(C.primary).backgroundColor(C.elevated).height(44).borderRadius(R.pill)
            .onSelect((index: number) => this.sortIndex = index)
        }.width('100%')
        if (this.query.trim().length > 0) {
          Text($r('app.string.search_results', filterGames(this.games, this.query).length)).fontSize(13).fontColor(C.tertiary)
        }
      }.padding({ left: this.inset(), right: this.inset() }).alignItems(HorizontalAlign.Start)
      if (this.loading) this.skeleton()
      else if (filterGames(this.games, this.query).length === 0) {
        this.emptyState(this.games.length === 0 ? $r('app.string.no_games') : $r('app.string.no_matches'), this.games.length === 0)
      } else if (this.layout() === 'covers') {
        List({ space: 24 }) {
          ForEach(this.shown(), (game: Game) => {
            ListItem() { this.coverCard(game) }
          }, (game: Game) => game.key + (game.favorite ? '*' : ''))
        }.listDirection(Axis.Horizontal).alignListItem(ListItemAlign.Center).layoutWeight(1).width('100%')
          .contentStartOffset(this.inset()).contentEndOffset(this.inset()).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
      } else if (this.layout() === 'grid') {
        Grid() {
          ForEach(this.shown(), (game: Game) => {
            GridItem() { this.gridCard(game) }
          }, (game: Game) => game.key)
        }.columnsTemplate(this.columns()).columnsGap(12).rowsGap(20).layoutWeight(1)
          .padding({ left: this.inset(), right: this.inset(), bottom: 40 }).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
      } else {
        List({ space: 12 }) {
          ForEach(this.shown(), (game: Game) => {
            ListItem() { this.columnCard(game) }
          }, (game: Game) => game.key + (game.favorite ? '*' : ''))
        }.layoutWeight(1).width('100%').padding({ left: this.inset(), right: this.inset() })
          .contentEndOffset(40).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      }
    }.width('100%').height('100%')
  }

  @Builder settingsRow(symbol: Resource, label: ResourceStr, value: string, id: string, callback: () => void) {
    Row({ space: 14 }) {
      SymbolGlyph(symbol).fontSize(20).fontColor([C.secondary])
      Text(label).fontSize(16).fontColor(C.primary)
      Blank()
      if (value.length > 0) Text(value).fontSize(14).fontColor(C.tertiary).maxLines(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([C.tertiary])
    }.id(id).height(L.row).width('100%').padding({ left: 16, right: 14 }).onClick(callback)
  }

  @Builder settings() {
    Scroll() {
      Column({ space: 16 }) {
        this.backBar($r('app.string.settings'), 's2arm-settings-back')
        Column() {
          this.settingsRow($r('sys.symbol.gamecontroller'), $r('app.string.controls_feedback'),
            this.controller.length > 0 ? this.controller : str($r('app.string.touchscreen')), 's2arm-settings-input', this.onSettings)
          if (this.games.length > 0) {
            Divider().color(C.separator).margin({ left: 50 })
            this.settingsRow($r('sys.symbol.square_grid_2x2'), $r('app.string.touch_layout'), this.touchValue, 's2arm-settings-touch', this.onControls)
          }
        }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true).margin({ left: this.inset(), right: this.inset() })
        Column() {
          this.settingsRow($r('sys.symbol.arrow_down_to_line'), $r('app.string.runtime_logs'), '', 's2arm-settings-diag', this.onDiagnostics)
        }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true).margin({ left: this.inset(), right: this.inset() })
        if (this.version.length > 0) {
          Text(this.version).fontSize(12).fontColor(C.tertiary).width('100%').textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
      }.width('100%').padding({ bottom: 40 })
    }.height('100%').width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder destination(name: string) {
    if (name === 'Settings') {
      NavDestination() { this.settings() }.hideTitleBar(true).backgroundColor(C.base)
    } else if (name === 'GameDetail' && this.current() !== undefined) {
      NavDestination() {
        Stack({ alignContent: Alignment.Top }) {
          Image(this.cover(this.current()!)).width('100%').height('70%').objectFit(ImageFit.Cover)
            .blur(64).opacity(0.5).hitTestBehavior(HitTestMode.None)
          Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
            .linearGradient({ angle: 180, colors: [['#330B0B0F', 0.0], ['#CC0B0B0F', 0.45], [C.base, 0.7]] })
          Scroll() {
            Column({ space: 20 }) {
              Stack() { this.artwork(this.current()!) }
                .width('100%').aspectRatio(16 / 9).constraintSize({ maxHeight: 380 }).borderRadius(R.xl).clip(true)
                .shadow({ radius: 32, color: '#66000000', offsetY: 12 })
                .geometryTransition('hero-' + this.current()!.key)
              Row({ space: 12 }) {
                Text(this.current()!.title).fontSize(26).lineHeight(32).fontWeight(FontWeight.Bold)
                  .fontColor(C.primary).maxLines(3).layoutWeight(1)
                Stack() {
                  SymbolGlyph(this.current()!.favorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
                    .fontSize(22).fontColor([this.current()!.favorite ? C.primary : C.secondary])
                }.id('s2arm-favorite').width(L.target).height(L.target).onClick(this.onFavorite)
                  .accessibilityText(this.current()!.favorite ? $r('app.string.unfavorite') : $r('app.string.favorite'))
              }.width('100%').alignItems(VerticalAlign.Top)
              if (this.message.length > 0) Text(this.message).fontSize(14).fontColor(C.error)
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.play_fill')).fontSize(18).fontColor([C.inverse])
                Text(this.startGameLabel(this.current()!)).fontSize(17).fontWeight(FontWeight.Medium)
                  .fontColor(C.inverse)
              }.id('s2arm-detail-start').width('100%').height(52).justifyContent(FlexAlign.Center)
                .borderRadius(R.pill).backgroundColor(this.ready ? C.primary : '#66F5F5F7')
                .onClick(() => { if (this.ready) this.onStart(); })
              Column() {
                this.settingsRow($r('sys.symbol.square_grid_2x2'), $r('app.string.touch_layout'), this.touchValue, 's2arm-detail-touch', this.onControls)
              }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true)
            }.alignItems(HorizontalAlign.Start).padding({ left: this.inset(), right: this.inset(), top: 8, bottom: 40 })
              .width('100%')
          }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
            .padding({ top: L.header })
          Row() {
            this.iconButton($r('sys.symbol.chevron_left'), $r('app.string.back'), 's2arm-detail-back', () => { this.paths.pop(); })
          }.width('100%').height(L.header).padding({ left: this.inset() - 4 }).position({ x: 0, y: 0 })
        }.width('100%').height('100%')
      }.hideTitleBar(true).backgroundColor(C.base)
    }
  }

  build() {
    Navigation(this.paths) {
      Stack() {
        this.ambient()
        this.library()
      }.width('100%').height('100%')
    }.mode(NavigationMode.Stack).hideTitleBar(true).navDestination(this.destination)
      .width('100%').height('100%').backgroundColor(C.base)
      .onAreaChange((_old: Area, area: Area) => {
        this.pageWidth = Number(area.width);
        this.pageHeight = Number(area.height);
      })
  }
}
