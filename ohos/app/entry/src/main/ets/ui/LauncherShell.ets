// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// R-06 v1.3：首页（Hero + 最近）/ 游戏库 / 设置；沉浸光感悬浮底栏；详情走 Navigation。
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { C, R, L, M, Glass, IMMERSIVE } from './Theme';
import { Game, filterGames, sortGames } from './LibraryModel';

const SORTS: string[] = ['recent', 'title', 'favorite'];
const SORT_LABELS: string[] = ['最近', '名称', '收藏'];

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
  @State tab: number = 0;
  @State pressedKey: string = '';
  private paths: NavPathStack = new NavPathStack();

  private current(): Game | undefined { return this.games[this.selected]; }
  private inset(): number { return this.pageWidth >= 600 ? 24 : 16; }
  private cover(game: Game): string { return 'file://' + this.filesDir + '/games/' + game.key + '/game/icon.jpg'; }
  private select(game: Game): void {
    this.getUIContext().animateTo({ duration: M.base, curve: Curve.Friction }, () => this.onSelect(game.key));
  }
  private open(game: Game): void {
    this.onSelect(game.key);
    this.paths.pushPath({ name: 'GameDetail' });
  }
  private startLabel(game: Game): string { return this.lastGame === game.key ? '继续' : '开始'; }
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
      MenuItem({ content: '开始游戏' }).enabled(this.ready).onClick(() => { this.onSelect(game.key); this.onStart(); })
      MenuItem({ content: game.favorite ? '取消收藏' : '收藏' }).onClick(() => { this.onSelect(game.key); this.onFavorite(); })
      MenuItem({ content: '触控布局' }).onClick(() => { this.onSelect(game.key); this.onControls(); })
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

  @Builder iconButton(symbol: Resource, label: string, id: string, action: () => void) {
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
      if (this.current() !== undefined && this.tab === 0) {
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

  @Builder header(title: string, importable: boolean = true) {
    Row() {
      Text(title).fontSize(28).fontWeight(FontWeight.Bold).fontColor(C.primary)
      Blank()
      if (importable) this.iconButton($r('sys.symbol.folder_badge_plus'), '导入游戏', 's2arm-import', this.onImport)
    }.height(L.header).width('100%').padding({ left: this.inset(), right: this.inset() })
  }

  @Builder emptyState(title: string, importable: boolean) {
    Column({ space: 20 }) {
      SymbolGlyph($r('sys.symbol.gamecontroller')).fontSize(56).fontColor([C.tertiary])
      Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(C.secondary)
      if (importable) {
        Text('导入游戏').id('s2arm-import-first').fontSize(16).fontWeight(FontWeight.Medium).fontColor(C.inverse)
          .height(L.cta).padding({ left: 28, right: 28 }).borderRadius(R.pill).backgroundColor(C.primary)
          .onClick(this.onImport)
      } else {
        Text('清除搜索').fontSize(16).fontColor(C.primary).height(L.cta).padding({ left: 24, right: 24 })
          .borderRadius(R.pill).backgroundColor(C.elevated2).onClick(() => this.query = '')
      }
    }.width('100%').height(320).justifyContent(FlexAlign.Center)
  }

  @Builder skeleton() {
    Column({ space: 24 }) {
      Column().width('100%').aspectRatio(16 / 9).borderRadius(R.xl).backgroundColor(C.elevated)
      Row({ space: 12 }) {
        ForEach([0, 1, 2], (i: number) => {
          Column().width(L.recent).height(L.recent).borderRadius(R.md).backgroundColor(C.elevated)
        }, (i: number) => i.toString())
      }.width('100%')
    }.padding({ left: this.inset(), right: this.inset(), top: 8 })
  }

  @Builder hero(game: Game) {
    Stack({ alignContent: Alignment.BottomStart }) {
      this.artwork(game)
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#000B0B0F', 0.35], ['#E60B0B0F', 1]] })
        .hitTestBehavior(HitTestMode.None)
      Row({ space: 12 }) {
        Text(game.title).fontSize(24).lineHeight(30).fontWeight(FontWeight.Bold).fontColor(C.primary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        this.playPill(game, 's2arm-start')
      }.width('100%').padding(20).alignItems(VerticalAlign.Bottom)
    }.width('100%').aspectRatio(16 / 9).constraintSize({ minHeight: 200, maxHeight: 380 })
      .borderRadius(R.xl).clip(true)
      .shadow({ radius: 32, color: '#66000000', offsetY: 12 })
      .geometryTransition('hero-' + game.key)
      .onClick(() => this.open(game)).accessibilityText(game.title + '，详情')
      .bindContextMenu(this.cardMenu(game), ResponseType.LongPress)
  }

  @Builder recentCard(game: Game) {
    Column({ space: 8 }) {
      Stack() { this.artwork(game) }
        .width(L.recent).height(L.recent).borderRadius(R.md).clip(true)
        .border({ width: 2, color: this.current()?.key === game.key ? C.primary : Color.Transparent })
      Text(game.title).fontSize(14).fontColor(this.current()?.key === game.key ? C.primary : C.secondary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width(L.recent)
    }.width(L.recent)
      .scale(this.pressedKey === game.key ? { x: 0.96, y: 0.96 } : { x: 1, y: 1 })
      .animation({ duration: M.fast, curve: Curve.Friction })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) this.pressedKey = game.key;
        else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.pressedKey = '';
      })
      .onClick(() => { if (this.current()?.key === game.key) this.open(game); else this.select(game); })
      .bindContextMenu(this.cardMenu(game), ResponseType.LongPress)
      .focusable(true).accessibilityText(game.title)
  }

  @Builder home() {
    Scroll() {
      Column({ space: 24 }) {
        this.header('S2Arm')
        if (this.loading) this.skeleton()
        else if (this.games.length === 0) this.emptyState('还没有游戏', true)
        else {
          Column({ space: 12 }) {
            if (this.crashTitle.length > 0) {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([C.error])
                Text('上次运行中断').fontSize(14).fontColor(C.error)
                Blank()
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([C.tertiary])
              }.width('100%').height(L.target).padding({ left: 16, right: 12 }).borderRadius(R.lg)
                .backgroundColor('#1AFF453A').onClick(this.onDiagnostics)
            }
            if (this.current() !== undefined) {
              ForEach([this.current()!], (game: Game) => {
                Column() { this.hero(game) }.width('100%')
                  .transition(TransitionEffect.OPACITY.animation({ duration: M.base, curve: Curve.Friction }))
              }, (game: Game) => game.key + (game.favorite ? '*' : ''))
            }
            if (this.message.length > 0) Text(this.message).fontColor(C.error).fontSize(14).maxLines(3)
          }.padding({ left: this.inset(), right: this.inset() })
          Column({ space: 12 }) {
            Text('最近').fontSize(20).fontWeight(FontWeight.Bold).fontColor(C.primary)
              .padding({ left: this.inset() })
            List({ space: 12 }) {
              ForEach(sortGames(this.games, 'recent'), (game: Game) => {
                ListItem() { this.recentCard(game) }
              }, (game: Game) => game.key)
            }.listDirection(Axis.Horizontal).height(L.recent + 34).scrollBar(BarState.Off)
              .contentStartOffset(this.inset()).contentEndOffset(this.inset())
              .edgeEffect(EdgeEffect.Spring)
          }.alignItems(HorizontalAlign.Start).width('100%')
        }
      }.width('100%').padding({ bottom: 120 })
    }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
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
      this.header('游戏库')
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Search({ value: this.query, placeholder: '搜索' }).height(44).layoutWeight(1)
            .backgroundColor(C.elevated).fontColor(C.primary).placeholderColor(C.tertiary)
            .onChange((value: string) => this.query = value)
          Select(SORT_LABELS.map((label: string): SelectOption => ({ value: label })))
            .selected(this.sortIndex).value(SORT_LABELS[this.sortIndex])
            .font({ size: 14 }).fontColor(C.primary).backgroundColor(C.elevated).height(44).borderRadius(R.pill)
            .onSelect((index: number) => this.sortIndex = index)
        }.width('100%')
        if (this.query.trim().length > 0) {
          Text(filterGames(this.games, this.query).length.toString() + ' 个结果').fontSize(13).fontColor(C.tertiary)
        }
      }.padding({ left: this.inset(), right: this.inset() }).alignItems(HorizontalAlign.Start)
      if (this.loading) this.skeleton()
      else if (filterGames(this.games, this.query).length === 0) {
        this.emptyState(this.games.length === 0 ? '还没有游戏' : '没有匹配的游戏', this.games.length === 0)
      } else {
        Grid() {
          ForEach(sortGames(filterGames(this.games, this.query), SORTS[this.sortIndex]), (game: Game) => {
            GridItem() { this.gridCard(game) }
          }, (game: Game) => game.key)
        }.columnsTemplate(this.columns()).columnsGap(12).rowsGap(20).layoutWeight(1)
          .padding({ left: this.inset(), right: this.inset(), bottom: 120 }).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
      }
    }.width('100%').height('100%')
  }

  @Builder settingsRow(symbol: Resource, label: string, value: string, id: string, callback: () => void) {
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
        this.header('设置', false)
        Column() {
          this.settingsRow($r('sys.symbol.gamecontroller'), '控制与反馈', this.controller || '触屏', 's2arm-settings-input', this.onSettings)
          if (this.games.length > 0) {
            Divider().color(C.separator).margin({ left: 50 })
            this.settingsRow($r('sys.symbol.square_grid_2x2'), '触控布局', this.touchValue, 's2arm-settings-touch', this.onControls)
          }
        }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true).margin({ left: this.inset(), right: this.inset() })
        Column() {
          this.settingsRow($r('sys.symbol.arrow_down_to_line'), '运行日志', '', 's2arm-settings-diag', this.onDiagnostics)
        }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true).margin({ left: this.inset(), right: this.inset() })
        if (this.version.length > 0) {
          Text(this.version).fontSize(12).fontColor(C.tertiary).width('100%').textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
      }.width('100%').padding({ bottom: 120 })
    }.height('100%').width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder destination(name: string) {
    if (name === 'GameDetail' && this.current() !== undefined) {
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
                  .accessibilityText(this.current()!.favorite ? '取消收藏' : '收藏')
              }.width('100%').alignItems(VerticalAlign.Top)
              if (this.message.length > 0) Text(this.message).fontSize(14).fontColor(C.error)
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.play_fill')).fontSize(18).fontColor([C.inverse])
                Text(this.startLabel(this.current()!) + '游戏').fontSize(17).fontWeight(FontWeight.Medium)
                  .fontColor(C.inverse)
              }.id('s2arm-detail-start').width('100%').height(52).justifyContent(FlexAlign.Center)
                .borderRadius(R.pill).backgroundColor(this.ready ? C.primary : '#66F5F5F7')
                .onClick(() => { if (this.ready) this.onStart(); })
              Column() {
                this.settingsRow($r('sys.symbol.square_grid_2x2'), '触控布局', this.touchValue, 's2arm-detail-touch', this.onControls)
              }.borderRadius(R.lg).backgroundColor(C.elevated).clip(true)
            }.alignItems(HorizontalAlign.Start).padding({ left: this.inset(), right: this.inset(), top: 8, bottom: 40 })
              .width('100%')
          }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
            .padding({ top: L.header })
          Row() {
            this.iconButton($r('sys.symbol.chevron_left'), '返回', 's2arm-detail-back', () => { this.paths.pop(); })
          }.width('100%').height(L.header).padding({ left: this.inset() - 4 }).position({ x: 0, y: 0 })
        }.width('100%').height('100%')
      }.hideTitleBar(true).backgroundColor(C.base)
    }
  }

  build() {
    Navigation(this.paths) {
      Stack() {
        this.ambient()
        Tabs({ barPosition: BarPosition.End, index: this.tab }) {
          TabContent() { this.home() }
            .tabBar(BottomTabBarStyle.of({ normal: new SymbolGlyphModifier($r('sys.symbol.house')).fontColor([C.secondary]),
              selected: new SymbolGlyphModifier($r('sys.symbol.house_fill')).fontColor([C.primary]) }, '首页')
              .labelStyle({ unselectedColor: C.secondary, selectedColor: C.primary })
              .iconStyle({ unselectedColor: C.secondary, selectedColor: C.primary }))
          TabContent() { this.library() }
            .tabBar(BottomTabBarStyle.of({ normal: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')).fontColor([C.secondary]),
              selected: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')).fontColor([C.primary]) }, '游戏库')
              .labelStyle({ unselectedColor: C.secondary, selectedColor: C.primary })
              .iconStyle({ unselectedColor: C.secondary, selectedColor: C.primary }))
          TabContent() { this.settings() }
            .tabBar(BottomTabBarStyle.of({ normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')).fontColor([C.secondary]),
              selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill')).fontColor([C.primary]) }, '设置')
              .labelStyle({ unselectedColor: C.secondary, selectedColor: C.primary })
              .iconStyle({ unselectedColor: C.secondary, selectedColor: C.primary }))
        }.barHeight(L.tab).scrollable(false).animationDuration(0)
          .barOverlap(true)
          .barFloatingStyle({ systemMaterial: Glass.bar, barBottomMargin: 12, barSideMargin: 48 })
          .onChange((index: number) => this.tab = index)
      }.width('100%').height('100%')
    }.mode(NavigationMode.Stack).hideTitleBar(true).navDestination(this.destination)
      .width('100%').height('100%').backgroundColor(C.base)
      .onAreaChange((_old: Area, area: Area) => this.pageWidth = Number(area.width))
  }
}
