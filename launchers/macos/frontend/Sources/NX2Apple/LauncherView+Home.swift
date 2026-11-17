// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import NXCore
import NXLauncher
import S2ArmAppleAdapter

extension LauncherView {
    var homeGames: [GameSummary] { home.games(model.games) }
    var homeSelected: GameSummary? { homeGames.first { $0.id == model.selectedID } ?? homeGames.first }

    func homeLibrary(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            staleBanner
            renewBanner
            homeControls(size: size).padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.top, size.height < 740 ? 12 : 22).padding(.bottom, 18)
            if homeGames.isEmpty {
                homeEmptyPreview
            } else {
                homeCoverStrip(size: size)
                Spacer(minLength: 12)
                if let game = homeSelected {
                    homePreview(game, size: size).padding(.horizontal, 54).padding(.bottom, size.height < 740 ? 24 : 42)
                }
            }
            homeFooter
        }
        .onAppear { reconcileHomeSelection() }
        .onChange(of: home.group) { _ in reconcileHomeSelection() }
        .onChange(of: home.search) { _ in reconcileHomeSelection() }
        .onChange(of: homeGames.map(\.id)) { _ in reconcileHomeSelection() }
    }

    private var homeEmptyPreview: some View {
        VStack(spacing: 18) {
            Image(systemName: home.group.symbol)
                .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text(loc.t(home.search.isEmpty ? "home.empty." + home.group.rawValue : "home.noResults"))
                .font(.manrope(20, .semibold)).multilineTextAlignment(.center)
            Button { home.group = .all; home.search = "" } label: { Image(systemName: "square.grid.2x2") }
                .controllerButtonStyle(ConsoleIconButtonStyle(size: 48))
                .help(loc.t("home.showAll")).accessibilityLabel(loc.t("home.showAll")).controllerID("home.showAll")
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    /// 游玩时间：玩家在意的数，单独一块放大——数字大号加粗，单位与「哪天」小一号；规则同 iPhone 游戏库（GamePlaytime）
    private func playtimeBadge(_ playtime: GamePlaytime) -> some View {
        let p = playtime.parts(now: Date(), calendar: .current, locale: Locale(identifier: uiLanguage), text: txt)
        let template = txt(p.template)
        let split = template.components(separatedBy: "{0}")
        var line = AttributedString(split.first ?? "")
        line.font = Font.manrope(15, .medium); line.foregroundColor = .white.opacity(0.75)
        var number = AttributedString(p.number)
        number.font = Font.manrope(24, .bold); number.foregroundColor = LauncherPalette.cream
        line.append(number)
        var unit = AttributedString(split.dropFirst().joined(separator: "{0}"))
        unit.font = Font.manrope(15, .medium); unit.foregroundColor = .white.opacity(0.75)
        line.append(unit)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "clock.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(LauncherPalette.cream)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(line).monospacedDigit().lineLimit(1)
            Text(p.when).font(.manrope(13, .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine).accessibilityIdentifier("hero.playtime")
    }

    private func homePreview(_ game: GameSummary, size: CGSize) -> some View {
        let compact = size.height < 740
        return VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            Text(game.name).font(.manrope(compact ? 34 : min(48, size.width * 0.04), .bold)).tracking(-1)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 2)
            VStack(alignment: .leading, spacing: 8) {
                if !compact {
                    Text(game.id).font(.manrope(12, .medium)).monospaced().tracking(1.5).foregroundStyle(.white.opacity(0.65))
                }
                status(game).lineLimit(2)
            }
            if let playtime = game.playtime { playtimeBadge(playtime) }
            if game.playable, game.hostUpdate == "incompatible" {
                // 新版改了宿主读产物的约定、换不了宿主：旧版本照常能玩，重新出一次 Mac 版才能用上新版修复（host_update.py；主线游戏库同一句）
                HStack(spacing: 10) {
                    Text(txt("library.hostUpdate.incompatible")).font(.manrope(12.5)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    Button(txt("library.hostUpdate.prepare")) { model.exportFor = game.id }
                        .buttonStyle(.link).disabled(model.mainBusy).controllerID("hero.hostUpdate")
                }
            }
            if let error = model.actionError(for: game.id) {
                Text(loc.backend(error)).font(.manrope(12)).foregroundStyle(LauncherPalette.danger).lineLimit(2)
            }
            HStack(spacing: 14) {
                Button { homePrimary(game) } label: { Label(homePrimaryTitle(game), systemImage: homePrimarySymbol(game)) }
                    .controllerButtonStyle(ConsolePlayButtonStyle()).disabled(model.cloudSyncing)
                    .keyboardShortcut(.return, modifiers: [])
                    .help(homePrimaryTitle(game)).accessibilityLabel(homePrimaryTitle(game))
                    .controllerID(game.playable ? "hero.play" : game.iphoneReady ? "hero.install" : "hero.export").controllerShortcut(.rightTrigger)
                Button {
                    model.exportSelfSign(game)
                    if game.iphoneExportable { installFor = game.id }
                } label: {
                    fitLabel(txt("library.hero.selfSign"), "square.and.arrow.up")
                }
                .controllerButtonStyle(ConsolePillButtonStyle()).controllerID("hero.selfSign")
                .help(txt("library.hero.selfSign")).accessibilityLabel(txt("library.hero.selfSign"))
                // 能直接导出的走手机槽（出包在跑也行，手机槽忙就排队）；要先出 iPhone 包的，主槽在跑非出包作业时等（出包在跑会排队）
                .disabled(game.iphoneExportable ? model.phoneQueued(game.id) : model.mainBusy && model.session?.export == nil)
                // 主按钮是「开始游戏」时，出过 iPhone 包的款照样要能一键装到 iPhone（主线游戏库两个都在）
                if game.playable, game.iphoneReady {
                    Button { model.selfSigning = false; model.targetInstalledDevice(of: game); installFor = game.id } label: {
                        fitLabel(txt(game.iphoneInstalledAt != nil && game.iphoneFree ? "library.hero.renew" : "library.hero.install"), "iphone")
                    }
                    .controllerButtonStyle(ConsolePillButtonStyle()).controllerID("hero.install")   // 只开装机窗：别的作业在跑，窗里点装机会排队
                    .help(txt(game.iphoneInstalledAt != nil && game.iphoneFree ? "library.hero.renew" : "library.hero.install"))
                }
                // 只留两个人人认得的圆钮（…、♡）；「查看出包结果」「启动设置」收进「…」菜单（11-16 维护者：三条横杠看不出是启动设置，一行三种形状不统一）
                Button { moreFor = game.id } label: { Image(systemName: "ellipsis") }
                    .controllerButtonStyle(ConsoleIconButtonStyle(size: 52)).controllerID("hero.more")
                    .help(loc.t("home.details")).accessibilityLabel(loc.t("home.details"))
                    .popover(isPresented: Binding(get: { moreFor == game.id }, set: { if !$0 { moreFor = nil } }), arrowEdge: .bottom) { moreMenu(game) }
                Button { home.toggleFavorite(game.id) } label: {
                    Image(systemName: home.favorites.contains(game.id) ? "heart.fill" : "heart")
                }.controllerButtonStyle(ConsoleIconButtonStyle(size: 52)).controllerID("hero.favorite")
                    .help(loc.t(home.favorites.contains(game.id) ? "home.unfavorite" : "home.favorite"))
                    .accessibilityLabel(loc.t(home.favorites.contains(game.id) ? "home.unfavorite" : "home.favorite"))
                    .accessibilityAddTraits(home.favorites.contains(game.id) ? .isSelected : [])
            }.padding(.top, compact ? 4 : 10)
        }
        .frame(maxWidth: min(740, size.width * 0.64), alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("home.preview")
    }

    /// 游戏卡次按钮的标签：整句放得下就带字，放不下（窄窗、法语这类长译文）只留图标，不截成半句（W1 同一原则：放不下就收成图标）；说明在 .help 里
    private func fitLabel(_ title: String, _ symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).lineLimit(1).fixedSize()
            Image(systemName: symbol)
        }
    }

    private func homeControls(size: CGSize) -> some View {
        HStack(spacing: 10) {
            homeGroups(compact: size.width < 1200)
            Text("\(homeGames.count) / \(model.games.count)").font(.manrope(11.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6)).fixedSize().accessibilityIdentifier("home.count").padding(.leading, 24)
            Spacer(minLength: 16)
            HomeSearchControl(isExpanded: $showHomeSearch, text: $home.search,
                              width: size.width < 1000 ? min(LauncherControl.width, max(140, size.width - 660))
                                  : size.width < 1200 ? LauncherControl.width : LauncherTheme.Metrics.navigationWidth) { finished in
                navigation.focus("home.search.field")
                navigation.editText(value: home.search, label: loc.t("home.search"), onClose: finished) { home.search = $0 }
            }
            Button { model.sgradeUpgradeOpen = true } label: {
                Image(nsImage: SGradeCardView.sGold).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            }.controllerButtonStyle(ConsoleIconButtonStyle()).disabled(model.busy || model.games.isEmpty)
                .controllerID("library.sgradeUpgrade")
                .help(txt("sgrade.upgrade.button")).accessibilityLabel(txt("sgrade.upgrade.button"))
            Button { model.showAddGames = true } label: {
                Image(systemName: "plus")
            }
            .controllerButtonStyle(ConsoleIconButtonStyle())
            .disabled(model.busy)
            .help(loc.t("s2arm.action.import")).accessibilityLabel(loc.t("s2arm.action.import")).controllerID("top.import")
            Button { showHomeMore.toggle() } label: { Image(systemName: "ellipsis") }
                .controllerButtonStyle(ConsoleIconButtonStyle()).controllerID("home.more")
                .help(loc.t("home.details")).accessibilityLabel(loc.t("home.details"))
                .popover(isPresented: $showHomeMore, arrowEdge: .bottom) { homeMoreMenu }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showHomeSearch)
    }

    private var homeMoreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            homeMoreRow(loc.t("s2arm.library.refresh"), "arrow.clockwise", id: "home.refresh") { model.refresh() }
                .disabled(model.loading)
            Divider().opacity(0.3).padding(.vertical, 4)
            homeMoreRow(txt("report.button"), "exclamationmark.bubble", id: "top.report") { model.diagUploadFor = "" }
        }
        .padding(8).frame(width: 220).font(.manrope(13.5, .semibold)).preferredColorScheme(.dark)
    }

    private func homeMoreRow(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button { showHomeMore = false; action() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20, height: 20)
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
        }
        .controllerButtonStyle(.plain).controllerID(id)
    }

    private func homeCoverStrip(size: CGSize) -> some View {
        let side = min(148, max(106, size.width * 0.105))
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(homeGames) { game in
                        homeCard(game, side: side).id("card." + game.id)
                    }
                }.padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.top, 6).padding(.bottom, 20)
            }
            .frame(height: side * 1.36 + 36, alignment: .top)
            .accessibilityIdentifier("home.covers")
            .onAppear { if let game = homeSelected { proxy.scrollTo("card." + game.id, anchor: .center) } }
            .onChange(of: model.selectedID) { id in
                guard let id else { return }
                let target = "card." + id
                if !navigation.isFullyVisible(target) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .onChange(of: navigation.focusedID) { id in
                guard let id, id.hasPrefix("card.") else { return }
                let gameID = String(id.dropFirst(5))
                guard homeGames.contains(where: { $0.id == gameID }) else { return }
                if model.selectedID != gameID { model.selectedID = gameID }
                if !navigation.isFullyVisible(id) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        // A different result set owns a fresh scroll position, even when the selected game ID stays unchanged.
        .id(homeGames.map(\.id))
    }

    private func homeGroups(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 24) {
            ForEach(HomeGroup.allCases, id: \.self) { group in
                Button { home.group = group } label: {
                    Group {
                        if compact {
                            Image(systemName: group.symbol)
                                .frame(width: 40, height: 40)
                        } else {
                            Label(loc.t("home.group." + group.rawValue), systemImage: group.symbol)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                        .font(.manrope(14, home.group == group ? .bold : .medium))
                        .foregroundStyle(.white.opacity(home.group == group ? 1 : 0.6))
                        .padding(.vertical, compact ? 0 : 10)
                        .overlay(alignment: .bottom) { Capsule().fill(.white.opacity(home.group == group ? 0.9 : 0)).frame(height: 2) }
                        .contentShape(Rectangle())
                }.controllerButtonStyle(.plain).controllerID("home.group." + group.rawValue)
                    .help(loc.t("home.group." + group.rawValue)).accessibilityLabel(loc.t("home.group." + group.rawValue))
                    .accessibilityAddTraits(home.group == group ? .isSelected : [])
            }
        }
    }

    private func homeCard(_ game: GameSummary, side: CGFloat) -> some View {
        let selected = homeSelected?.id == game.id
        let focused = navigation.visible && navigation.focusedID == "card." + game.id
        let artworkSide = selected ? side * 1.36 : side
        return Button {
            model.selectedID = game.id
            navigation.focus("card." + game.id)
            if game.location.state == "missing" { missingFor = game }
        } label: {
            GameArtwork(covers: covers, cover: game.cover).frame(width: artworkSide, height: artworkSide)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 15))
                .overlay(alignment: .topLeading) {
                    if game.sgrade { SGradeBadge(size: max(24, artworkSide / 9)) }
                }
                .overlay(alignment: .topTrailing) {
                    if home.favorites.contains(game.id) {
                        Image(systemName: "heart.fill").font(.system(size: 10)).padding(6).background(.black.opacity(0.6), in: Circle()).padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) { expiryBadge(game) }
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(focused ? 1 : selected ? 0.9 : 0), lineWidth: focused ? 3 : 2))
                .shadow(color: .black.opacity(selected ? 0.4 : 0.2), radius: selected ? 12 : 6, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.controllerButtonStyle(.plain)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: selected)
            .help(game.name + " · " + statusLine(game).text)
            .accessibilityLabel(game.name).accessibilityValue(statusLine(game).text)
            .accessibilityAddTraits(selected ? .isSelected : []).controllerID("card." + game.id)
            .contextMenu { cardMenu(game) }
            .modifier(CardDrop(targeted: cardTargeted(game.id), artwork: artworkSide + 10) { dropOnCard($0, game: game) })
    }

    /// 卡片上的 iPhone 签名角标（旧版每张卡片下都有「还有 N 天 / 已过期」，新主题只在选中那款显示）：免费账号装过的款才有；
    ///   还剩 1–2 天橙色、过期红色，其余白字深底——扫一眼就知道哪款要续签
    @ViewBuilder func expiryBadge(_ game: GameSummary) -> some View {
        if game.iphoneInstalledAt != nil, let days = game.iphoneDaysLeft() {
            let color: Color = days == 0 ? LauncherPalette.danger : days <= 2 ? .orange : .white
            Label(days == 0 ? loc.t("home.card.expired") : String(format: loc.t("home.card.daysLeft"), days), systemImage: "iphone")
                .font(.manrope(11, .bold)).labelStyle(ConsoleBadgeLabelStyle())
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.black.opacity(0.68), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(days <= 2 ? 0.7 : 0.18)))
                .padding(8)
                .accessibilityIdentifier("card.expiry." + game.id)
        }
    }

    private var homeFooter: some View {
        HStack(spacing: 20) {
            Label(loc.t("home.navigate"), systemImage: "dpad").font(.manrope(11.5))
            Spacer(minLength: 8)
            homeHint(.rightTrigger, homeSelected.map(homePrimaryTitle) ?? loc.t("home.select"))
            homeHint(.back, loc.t("home.back"))
            homeHint(.tertiary, loc.t("home.details"))
        }.foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 54).frame(height: 48)
            .accessibilityIdentifier("home.controller-hints").controllerConnectedOnly()
    }
    private func homeHint(_ shortcut: PadShortcut, _ title: String) -> some View {
        HomeControllerHint(presentation: navigation.presentation, shortcut: shortcut, title: title)
    }
    // 主按钮只在主槽有作业（出包 / 一局 / 导入…）时变成「回到当前任务」；手机作业在顶栏胶囊里看，不占主按钮
    private func homePrimarySymbol(_ game: GameSummary) -> String {
        if model.mainBusy { return "arrow.up.forward.app" }
        if game.playable { return model.cloudSyncing ? "arrow.triangle.2.circlepath" : "play.fill" }
        if game.iphoneReady { return "iphone.and.arrow.forward" }
        return "shippingbox"
    }
    func homePrimaryTitle(_ game: GameSummary) -> String {
        if model.mainBusy { return loc.t("home.currentTask") }
        if game.playable { return loc.t(model.cloudSyncing ? "s2arm.cloud.syncing" : "library.play") }
        if game.iphoneReady {
            return txt(game.iphoneInstalledAt != nil && game.iphoneFree ? "library.hero.renew" : "library.hero.install")
        }
        return loc.t("home.prepare")
    }
    func homePrimary(_ game: GameSummary) {
        if model.mainBusy {
            model.sessionHidden = false
            if model.batchRunning { model.batchShown = true }
            return
        }
        if game.location.state == "missing" { missingFor = game; return }
        if game.playable { model.play(game, uiLanguage: uiLanguage) }
        else if game.iphoneReady { model.selfSigning = false; model.targetInstalledDevice(of: game); installFor = game.id }
        else { model.exportFor = game.id }
    }
    func reconcileHomeSelection() {
        let games = homeGames
        if !games.contains(where: { $0.id == model.selectedID }), let first = games.first { model.selectedID = first.id }
        if let id = navigation.focusedID, id.hasPrefix("card."), !games.contains(where: { "card." + $0.id == id }) {
            navigation.focus(games.first.map { "card." + $0.id } ?? "home.search")
        }
    }
    var showingHome: Bool {
        if model.showsWelcome || model.batchShown || model.viewingResult != nil || model.exportFor != nil { return false }
        if let session = model.session, !model.sessionHidden, !model.isInline(session) { return false }
        return true
    }
    func configurePadNavigation() {
        navigation.language = uiLanguage
        navigation.text = { loc.t($0) }
        navigation.defaultFocus = { showingHome ? homeSelected.map { "card." + $0.id } : nil }
        navigation.context = { showingHome ? "home" : model.showsWelcome ? "welcome" : "job.\(model.exportFor ?? model.session?.kind.rawValue ?? "")" }
        navigation.source.relayPath = { model.controller.phase == .ready && !model.controller.assigning ? model.controller.socketURL.path : nil }
        navigation.source.relayAllowed = { !model.playSessionActive && !model.controller.assigning }
        navigation.source.relayConnected = { model.controller.deviceCount > 0 }
        navigation.source.assignment = { model.controller.assignment }
        navigation.source.faceMapping = { model.controller.faceMaps.mapping(for: $0) }
        navigation.onAction = { action in
            if action == .back, !showingHome, !model.showsWelcome { model.goToLibrary(); return true }
            guard showingHome else { return false }
            switch action {
            case .previousGroup, .nextGroup:
                home.cycle(action == .previousGroup ? -1 : 1)
                navigation.focus("home.group." + home.group.rawValue)
                return true
            case .details: if let game = homeSelected { moreFor = game.id }; return true
            // 左右移动就是选中；焦点所在的卡片按 A = 主操作（同 ZR）。提示列确认键统一显示 A，单只 Joy-Con 没有 ZR
            case .confirm:
                if let game = homeSelected, navigation.focusedID == "card." + game.id { navigation.handle(.submit); return true }
            case .search:
                navigation.focus("home.search")
                navigation.activateFocused(); return true
            case .back:
                if showHomeSearch { showHomeSearch = false; navigation.focus("home.search") }
                else if !home.search.isEmpty { home.search = "" }
                else if let game = homeSelected { navigation.focus("card." + game.id) }
                return true
            default: break
            }
            if action == .up, navigation.focusedID?.hasPrefix("hero.") == true, let game = homeSelected {
                navigation.focus("card." + game.id); return true
            }
            if action == .down, navigation.focusedID == "home.search", let game = homeSelected {
                navigation.focus("card." + game.id); return true
            }
            guard let id = navigation.focusedID, id.hasPrefix("card."),
                  let index = homeGames.firstIndex(where: { "card." + $0.id == id }) else { return false }
            switch action {
            case .left, .right:
                let next = index + (action == .left ? -1 : 1)
                if homeGames.indices.contains(next) {
                    model.selectedID = homeGames[next].id
                    navigation.focus("card." + homeGames[next].id)
                }
                return true
            case .down:
                let game = homeGames[index]
                navigation.focus(game.playable ? "hero.play" : game.iphoneReady ? "hero.install" : "hero.export")
                return true
            case .up: navigation.focus("home.search"); return true
            default: return false
            }
        }
    }
}

private struct HomeControllerHint: View {
    @ObservedObject var presentation: PadPresentation
    let shortcut: PadShortcut
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: presentation.symbols[shortcut.displayed] ?? shortcut.displayed.symbol).font(.system(size: 19))
            Text(title).font(.manrope(11.5))
        }.fixedSize()
    }
}

/// 角标里的小图标 + 字
struct ConsoleBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 10, weight: .bold)); configuration.title }
    }
}
