// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

/// 0.6.0 iPhone 总控台的界面（通用壳开关后面；《0.6.0 极简流程》界面一节）：游戏库首位固定「S2Arm」卡 + 选中它时下方整页。
///   开关关着（model.phoneOverview == nil）这里什么都不出，首页就是 0.5.x 的样子。
///   本段接了 ① 手机与 App、② 游戏同步、⑥ 帮助；③ 自签和证书、④ 空间、⑤ 存档与快照等对应作业进 main 后接。
extension LauncherView {
    private func sx(_ key: String) -> String { BackendText.launcherText(key, language: loc.lang.sharedCode) }
    private func sx(_ key: String, _ args: CustomStringConvertible...) -> String {
        args.enumerated().reduce(sx(key)) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element.description) }
    }

    var consoleEnabled: Bool { model.phoneOverview != nil }

    /// 首位卡状态行（随手机实时变；流程稿表格取第一条成立的）
    func consoleStatusText(_ s: S2ArmLauncherModel.ConsoleStatus) -> String {
        switch s {
        case .introduce: return sx("console.status.introduce")
        case .updating(let done, let total): return sx("console.status.updating", done + 1 > total ? total : done + 1, total)
        case .notConnected(let seen):
            return seen.map { sx("console.status.notConnected", $0.formatted(.relative(presentation: .named))) } ?? sx("console.status.notConnectedNever")
        case .externalApp: return sx("console.status.externalApp")
        case .notInstalled: return sx("console.status.notInstalled")
        case .appOutdated: return sx("console.status.appOutdated")
        case .expired: return sx("console.status.expired")
        case .expiring(let d): return sx("console.status.expiring", d)
        case .suggested(let n): return sx("console.status.suggested", n)
        case .ok(let d): return d.map { sx("console.status.ok", $0) } ?? sx("console.status.okNoDays")
        }
    }

    /// 游戏库首位「S2Arm」卡：S2Arm 图标叠手机轮廓，下面两行（手机名 / 状态）
    func consoleCard(side: CGFloat) -> some View {
        let selected = model.consoleSelected
        let focused = navigation.visible && navigation.focusedID == "card." + S2ArmLauncherModel.consoleID
        let artworkSide = selected ? side * 1.36 : side
        let status = model.consoleStatus()
        return Button {
            model.selectedID = S2ArmLauncherModel.consoleID
            navigation.focus("card." + S2ArmLauncherModel.consoleID)
        } label: {
            HomeCardSurface(selected: selected, focused: focused) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "iphone").font(.system(size: artworkSide * 0.46, weight: .thin)).foregroundStyle(.white.opacity(0.9))
                        .matchedGeometryEffect(id: "console.phone", in: consoleSpace, isSource: !selected)
                    Text("S2Arm").font(.manrope(artworkSide * 0.1, .bold)).foregroundStyle(.white).offset(y: artworkSide * 0.02)
                    if case .updating(let done, let total) = status {   // 动画 3 / 4：外圈进度环（更新所选 / 装 App 时）
                        Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1))).stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(artworkSide * 0.12)
                    }
                }
                .frame(width: artworkSide, height: artworkSide)
                .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.84), value: selected)
            }
        }.controllerButtonStyle(.plain)
            .help((model.consolePhone?.name ?? "S2Arm") + " · " + consoleStatusText(status))
            .accessibilityLabel("S2Arm").accessibilityValue((model.consolePhone?.name ?? "") + " · " + consoleStatusText(status))
            .accessibilityAddTraits(selected ? .isSelected : []).controllerID("card." + S2ArmLauncherModel.consoleID)
    }

    /// 选中首位卡时下方整页
    @ViewBuilder func consolePanel(size: CGSize) -> some View {
        let status = model.consoleStatus()
        if status == .introduce {
            consoleIntro
        } else if let phone = model.consolePhone {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    consoleHeader(phone, status: status)
                    consolePhoneSection(phone, status: status)
                    consoleSyncSection(phone)
                    consoleHelpSection
                }.frame(maxWidth: 860, alignment: .leading)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .accessibilityIdentifier("console.panel")
        }
    }

    /// 只在 Mac 上玩的人：三句介绍 +「连上 iPhone 开始」，不出空表、不出灰按钮墙
    private var consoleIntro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sx("console.status.introduce")).font(.manrope(30, .bold))
            Text(sx("console.intro.body")).font(.manrope(14)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
            Button { model.consoleIntroStart(language: loc.lang.sharedCode) } label: { Label(sx("console.intro.start"), systemImage: "iphone") }
                .controllerButtonStyle(ConsolePlayButtonStyle()).controllerID("console.intro.start")
        }.accessibilityIdentifier("console.intro")
    }

    /// 页顶：手机切换 + 大手机轮廓（动画 1：从封面升上来）+ 全部最新（动画 5）
    private func consoleHeader(_ phone: PhoneOverview.Phone, status: S2ArmLauncherModel.ConsoleStatus) -> some View {
        let phones = model.phoneOverview?.phones ?? []
        let allLatest = phone.installed && phone.shellCurrent && !phone.games.isEmpty && phone.games.allSatisfy { $0.state == .latest }
        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                Image(systemName: "iphone").font(.system(size: 64, weight: .thin)).foregroundStyle(.white)
                    .matchedGeometryEffect(id: "console.phone", in: consoleSpace, isSource: model.consoleSelected)
                if allLatest {
                    Text(sx("console.allLatest")).font(.manrope(9, .bold)).foregroundStyle(.green).shadow(color: .green.opacity(0.7), radius: 6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if phones.count > 1 {
                    Picker("", selection: Binding(get: { phone.device }, set: { model.consoleDevice = $0; model.seedConsoleSelection() })) {
                        ForEach(phones, id: \.device) { Text($0.name.isEmpty ? $0.device : $0.name).tag($0.device) }
                    }.labelsHidden().frame(maxWidth: 260).accessibilityIdentifier("console.phonePicker")
                } else {
                    Text(phone.name.isEmpty ? phone.device : phone.name).font(.manrope(22, .bold))
                }
                Text(consoleStatusText(status)).font(.manrope(13)).foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func consoleSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(12, .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var consoleOffline: Bool { if case .some(.none) = model.consolePhone?.online { return true }; return false }
    private func offlineReason(_ phone: PhoneOverview.Phone) -> some View {
        Text(sx("console.offline", phone.name.isEmpty ? "iPhone" : phone.name)).font(.manrope(12)).foregroundStyle(.orange)
    }

    /// 按钮文案键（动作名 → 共享文案；动作集合与控制口 phoneConsole 同一个来源 model.consoleActions）
    private func consoleActionTitle(_ a: S2ArmLauncherModel.ConsoleAction) -> String {
        switch a {
        case .installShell: return sx("console.button.install")
        case .updateShell: return sx("console.button.update")
        case .renewShell: return sx("console.button.renew")
        case .exportShellIpa: return sx("console.button.exportShellIpa")
        case .handOverIdentity: return sx("console.button.identity")
        case .updateSelected: return sx("console.updateSelected", model.consoleSelection.count)
        case .pushS2arm: return sx("console.button.pushS2arm", model.consoleSelection.count)
        case .exportS2arm: return sx("console.button.exportS2arm", model.consoleSelection.count)
        }
    }

    /// ① 手机与 App：App 状态 + 一个随状态变的按钮（启动器装的：安装 / 续签 / 更新 S2Arm；别的工具装的：导出 S2Arm.ipa）+ 签名方式
    private func consolePhoneSection(_ phone: PhoneOverview.Phone, status: S2ArmLauncherModel.ConsoleStatus) -> some View {
        let actions = model.consoleActions(phone)
        let app = actions.first { [.installShell, .updateShell, .renewShell, .exportShellIpa].contains($0) }
        return consoleSection(sx("console.section.phone")) {
            Text(consoleStatusText(status) + (phone.signMode.map { " · " + sx("console.sign." + $0.rawValue) } ?? "")).font(.manrope(14))
            if phone.installedBy == .external {
                Text(sx("console.external.note")).font(.manrope(12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            if let app {
                HStack(spacing: 12) {
                    // 导出 S2Arm.ipa 不连手机，没连也能点
                    Button { model.runConsoleAction(app, device: phone.device, language: loc.lang.sharedCode) } label: {
                        Label(consoleActionTitle(app), systemImage: app == .exportShellIpa ? "square.and.arrow.up" : "iphone.and.arrow.forward") }
                        .controllerButtonStyle(ConsolePillButtonStyle()).controllerID("console.app").disabled(consoleOffline && app != .exportShellIpa)
                    if consoleOffline && app != .exportShellIpa { offlineReason(phone) }
                }
            }
            if actions.contains(.handOverIdentity) { consoleIdentity(phone) }
        }.accessibilityIdentifier("console.section.phone")
    }

    /// 「把签名身份交给手机」（次要按钮）：AltStore / SideStore / 证书 App 装的 S2Arm 交一次签名身份，以后放进「放这里导入」就能玩。
    ///   进行中一行状态；成功一句完成提示（交好了 / 已经有了）；失败用手机作业的失败页（原因 + 下一步 + 复制错误摘要）
    @ViewBuilder private func consoleIdentity(_ phone: PhoneOverview.Phone) -> some View {
        let running = model.phoneBusy && model.phoneSession?.kind == .phoneIdentity
        VStack(alignment: .leading, spacing: 6) {
            Button { model.phoneIdentity(device: phone.device) } label: { Label(sx("console.button.identity"), systemImage: "person.badge.key") }
                .controllerButtonStyle(LauncherSecondaryButtonStyle()).controllerID("console.identity").disabled(consoleOffline || running)
            Text(sx("console.identity.note")).font(.manrope(12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(sx("phone.status.running.phoneIdentity")).font(.manrope(12.5)).foregroundStyle(.white.opacity(0.8))
                }
            } else if let last = model.lastPhoneSession, last.kind == .phoneIdentity {
                if last.phase == .finished(.completed), let delivered = model.identityDelivered {
                    Text(sx(delivered ? "console.identity.done" : "console.identity.already")).font(.manrope(13)).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("console.identity.result")
                } else if last.phase != .finished(.completed) {
                    PhoneJobPanel(model: model, session: last, showsOperation: false).padding(.top, 6)
                }
            }
        }.padding(.top, 6).accessibilityIdentifier("console.identity")
    }

    /// ② 游戏同步：每款一行写这台手机上的状态，可勾选；「更新所选」一款款推，有总进度、能停
    private func consoleSyncSection(_ phone: PhoneOverview.Phone) -> some View {
        consoleSection(sx("console.section.sync")) {
            ForEach(consoleOrdered) { game in
                let g = model.consoleGame(game)
                let id = game.id.uppercased()
                let pushing = model.consoleUpdating && model.consolePushing == id
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { model.consoleSelection.contains(id) },
                                             set: { if $0 { model.consoleSelection.insert(id) } else { model.consoleSelection.remove(id) } }))
                        .toggleStyle(.checkbox).labelsHidden().disabled(model.consoleUpdating)
                    GameArtwork(covers: covers, cover: game.cover).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay { if pushing { Circle().stroke(.orange, lineWidth: 2).padding(-3) } }
                    Text(game.name).font(.manrope(13, .medium)).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                    Text(consoleGameText(g)).font(.manrope(12.5, g.isLegacy ? .bold : .regular)).foregroundStyle(consoleGameColor(g)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("console.game." + id)
            }
            HStack(spacing: 12) {
                if !model.consoleUpdating {
                    // 启动器装的：更新所选；别的工具装的：推所选到 iPhone + 导出所选 .s2arm（导出不连手机，没连也能点）
                    ForEach(model.consoleActions(phone).filter { [.updateSelected, .pushS2arm, .exportS2arm].contains($0) }, id: \.self) { a in
                        let push = a != .exportS2arm
                        let button = Button { model.runConsoleAction(a, device: phone.device, language: loc.lang.sharedCode) } label: {
                            Label(consoleActionTitle(a), systemImage: push ? "arrow.down.to.line" : "square.and.arrow.up") }
                            .controllerID("console." + a.rawValue).disabled(model.consoleSelection.isEmpty || (push && consoleOffline))
                        if push { button.controllerButtonStyle(ConsolePlayButtonStyle()) } else { button.controllerButtonStyle(LauncherSecondaryButtonStyle()) }
                    }
                    if consoleOffline { offlineReason(phone) }
                } else {
                    let p = model.consoleProgress, total = max(p.total, 1)
                    let current = model.consolePushing.flatMap { id in model.games.first { $0.id.uppercased() == id }?.name }
                    ProgressView(value: Double(p.done), total: Double(total)).frame(maxWidth: 260)
                    Text(sx("console.progress", min(p.done + 1, total), total) + (current.map { " · " + $0 } ?? ""))
                        .font(.manrope(12.5)).foregroundStyle(.white.opacity(0.8))
                    Button(sx("console.stop")) { model.stopUpdateSelected() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.stop")
                }
            }
        }.accessibilityIdentifier("console.section.sync")
    }

    /// 0.5 → 0.6 升级后的老款（资源在、程序包不在）排最上面、醒目标出，直到更新完（更新完状态变了就回到游戏库顺序）
    private var consoleOrdered: [GameSummary] {
        let legacy = model.games.filter { model.consoleGame($0).isLegacy }
        return legacy + model.games.filter { !model.consoleGame($0).isLegacy }
    }

    private func consoleGameText(_ g: PhoneOverview.Game) -> String {
        if g.isLegacy { return sx("console.legacy.badge") }
        switch g.state {
        case .latest: return sx("console.game.latest")
        case .suggested: return sx("update.hint.badge") + " · " + g.reasons.compactMap(S2ArmLauncherModel.updateReasonKey).map(sx).joined(separator: " ")
        case .notPushed: return sx(g.dataOnComputer == false ? "console.game.notPushedNoData" : "console.game.notPushed")
        case .needsData: return sx(g.dataOnComputer == false ? "console.game.needsDataOriginal" : "console.game.needsData")
        }
    }
    private func consoleGameColor(_ g: PhoneOverview.Game) -> Color {
        if g.isLegacy { return LauncherPalette.building }
        switch g.state { case .latest: return .green; case .suggested: return .orange; case .notPushed: return .white.opacity(0.6); case .needsData: return .yellow }
    }

    /// ⑥ 帮助：重看第一次的引导（欢迎页）、故障报修（同顶栏那颗：全局「上传给开发者」）
    private var consoleHelpSection: some View {
        consoleSection(sx("console.section.help")) {
            HStack(spacing: 12) {
                Button(sx("console.help.guide")) { model.welcomeHome = true }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.help.guide")
                Button(sx("console.help.report")) { model.diagUploadFor = "" }.controllerButtonStyle(LauncherSecondaryButtonStyle()).accessibilityIdentifier("console.help.report")
            }
        }
    }
}

extension PhoneOverview.Game {
    /// 0.5.x 整包装的老款：资源推过、程序包不在（作业层 host_update.phone_overview suggested + missing）
    var isLegacy: Bool { state == .suggested && reasons.contains("missing") }
}
