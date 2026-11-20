// S2Arm（不是上游文件）：mod 导入旁的「？」（11-17 维护者：玩家不知道 mod 支持什么格式、去哪找）。鼠标移上去高亮并显示提示，点一下或手柄确认展开 / 收起说明（共享文案 mods.help：
//   支持的两类 mod、认哪几种放法、什么时候生效、不收什么、去哪找；controllerID 让手柄焦点走得到）。
//   启动设置「资源 Mod」一行（LaunchSettingsSheet）与出包页 S 级优化卡片的「导入 Mod」（SGradeCard）两处都放；Windows 同款在 ModsPage.cs ModHelp
import SwiftUI
import NXLauncher

struct ModHelpButton: View {
    let text: String
    let label: String
    let id: String
    @State private var shown = false
    @State private var hovered = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hovered ? LauncherPalette.cream : .secondary)
                .contentShape(Rectangle())
        }
        .controllerButtonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ScrollView {
                Text(text).font(.manrope(13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
            .frame(width: 440).frame(maxHeight: 520)
        }
        .accessibilityLabel(label).controllerID(id)
    }
}
