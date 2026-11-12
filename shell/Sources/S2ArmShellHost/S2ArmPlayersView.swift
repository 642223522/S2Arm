import SaveSync
import ShellUI
import SwiftUI

/// 本地玩家（#623）：游戏库顶部玩家按钮打开的切换页，盖在库界面上，只用触屏（开着时宿主停手柄监听，库界面背后不接按键）。
///   点一行 = 换成这个玩家并关页（同 Switch 选用户）；铅笔 = 改名；第一个玩家以外的可以从表里拿掉（存档不删）；底部加玩家（名字必填，建好即选上）。
struct S2ArmPlayersView: View {
    let players: [LocalPlayer]
    let current: String
    let select: (String) -> Void
    /// 返回 nil = 成了；否则是给玩家看的原因
    let add: (String) -> String?
    let rename: (String, String) -> String?
    let remove: (String) -> Void
    let close: () -> Void

    private enum Editing: Equatable { case none, adding, renaming(String), removing(String) }
    @State private var editing: Editing = .none
    @State private var text = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { close() }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shellText("Who’s playing?")).font(.system(size: 24, weight: .heavy)).tracking(-0.5).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("players.title")
                    Spacer(minLength: 12)
                    Button(shellText("Done")) { close() }.font(.system(size: 16, weight: .semibold)).foregroundStyle(ShellPalette.cream)
                        .accessibilityIdentifier("players.done")
                }
                Text(shellText("Each player has their own saves in every game. The game starts as the player picked here."))
                    .font(.system(size: 14)).foregroundStyle(ShellPalette.muted).fixedSize(horizontal: false, vertical: true)
                // 几个玩家时卡片按内容高；多到放不下才滚
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView { list }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.system(size: 13.5, weight: .medium)).foregroundStyle(ShellPalette.attention)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("players.error")
                }
            }
            .padding(24)
            .frame(maxWidth: 460, alignment: .leading)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(players) { row($0) }
            addRow
        }
    }

    @ViewBuilder private func row(_ player: LocalPlayer) -> some View {
        let isCurrent = player.uid == current
        switch editing {
        case .renaming(let uid) where uid == player.uid:
            field(placeholder: player.displayName, confirm: shellText("Save")) {
                if let why = rename(player.uid, text) { error = why } else { finish() }
            }
        case .removing(let uid) where uid == player.uid:
            VStack(alignment: .leading, spacing: 10) {
                Text(shellText("Remove \(player.displayName)? Their saves stay on this device. Add a player with the same name to get them back."))
                    .font(.system(size: 14)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(shellText("Cancel")) { finish() }.foregroundStyle(ShellPalette.muted).accessibilityIdentifier("players.remove.cancel")
                    Button(shellText("Remove")) { remove(player.uid); finish() }.foregroundStyle(ShellPalette.attention).fontWeight(.semibold)
                        .accessibilityIdentifier("players.remove.confirm")
                }.font(.system(size: 15))
            }
            .padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        default:
            HStack(spacing: 12) {
                Button { select(player.uid) } label: {
                    HStack(spacing: 12) {
                        Text(String(player.displayName.prefix(1)).uppercased()).font(.system(size: 17, weight: .bold))
                            .foregroundStyle(isCurrent ? ShellPalette.background : .white)
                            .frame(width: 38, height: 38).background(isCurrent ? ShellPalette.cream : Color.white.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.displayName).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            if isCurrent { Text(shellText("Playing now")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ShellPalette.ready) }
                        }
                        Spacer(minLength: 8)
                        if isCurrent { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(ShellPalette.cream) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.displayName + (isCurrent ? ", " + shellText("Playing now") : ""))
                .accessibilityIdentifier("players.row." + (player.isFirst ? "first" : player.uid))
                Button { start(.renaming(player.uid), text: player.name) } label: { Image(systemName: "pencil").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).foregroundStyle(ShellPalette.muted)
                    .accessibilityLabel(shellText("Rename") + ", " + player.displayName).accessibilityIdentifier("players.rename")
                if !player.isFirst {
                    Button { start(.removing(player.uid), text: "") } label: { Image(systemName: "trash").frame(width: 32, height: 32) }
                        .buttonStyle(.plain).foregroundStyle(ShellPalette.muted)
                        .accessibilityLabel(shellText("Remove") + ", " + player.displayName).accessibilityIdentifier("players.remove")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(isCurrent ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder private var addRow: some View {
        if editing == .adding {
            field(placeholder: shellText("Name"), confirm: shellText("Add")) {
                if let why = add(text) { error = why } else { finish() }
            }
        } else {
            Button { start(.adding, text: "") } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(ShellPalette.cream)
                        .frame(width: 38, height: 38).background(Color.white.opacity(0.06), in: Circle())
                    Text(shellText("Add Player")).font(.system(size: 16, weight: .semibold)).foregroundStyle(ShellPalette.cream)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("players.add")
        }
    }

    private func field(placeholder: String, confirm: String, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($fieldFocused).submitLabel(.done).onSubmit(commit)
                .accessibilityIdentifier("players.name")
            Button(shellText("Cancel")) { finish() }.foregroundStyle(ShellPalette.muted).accessibilityIdentifier("players.cancel")
            Button(confirm, action: commit).fontWeight(.semibold).foregroundStyle(ShellPalette.cream).accessibilityIdentifier("players.confirm")
        }
        .font(.system(size: 15))
        .padding(10).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func start(_ mode: Editing, text: String) {
        editing = mode; self.text = text; error = nil
        if mode != .none, case .removing = mode {} else { fieldFocused = true }
    }
    private func finish() { editing = .none; text = ""; error = nil; fieldFocused = false }
}
