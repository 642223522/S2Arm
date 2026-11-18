// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher

/// Compact controls keep the artwork visible; labels remain available to VoiceOver and on hover.
struct ConsoleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size > 44 ? 20 : 16, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : hovered ? 0.07 : 0)).allowsHitTesting(false))
            .overlay(Circle().strokeBorder(.white.opacity(hovered ? 0.4 : 0.12)))
            .contentShape(Circle())
            .onHover { hovered = $0 }
    }
}

/// 首页主操作（开始游戏 / 出包 / 装到 iPhone / 查看当前任务）：白底胶囊，图标 + 文字（11-16 维护者：只有图标时只有 ▶ 看得懂）。
///   高度与次要操作（ConsolePillButtonStyle）、圆钮（ConsoleIconButtonStyle size 52）同为 52，一行只差颜色不差形状
struct ConsolePlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ConsoleLabelStyle())
            .font(.manrope(16, .bold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 24)
            .frame(minWidth: 92, minHeight: 52, maxHeight: 52)
            .foregroundStyle(.black.opacity(0.85))
            .background(LauncherPalette.cream.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.4), in: Capsule())
            .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(hovered ? 1 : 0), lineWidth: 2).padding(-4))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}

/// 首页次要操作（导出自签包 / 装到 iPhone）：与主按钮同高同胶囊，深色磨砂底 + 细边（同圆钮），只是不用白底
struct ConsolePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ConsoleLabelStyle())
            .font(.manrope(15, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(minHeight: 52, maxHeight: 52)
            .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : hovered ? 0.07 : 0)).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(.white.opacity(hovered ? 0.4 : 0.12)))
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}

/// 图标 + 文字，图标比文字略大、垂直居中
struct ConsoleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 17, weight: .semibold))
            configuration.title
        }
    }
}

// 圆钮 / 胶囊：焦点框跟着画成圆 / 胶囊
extension ConsoleIconButtonStyle: PadRingShaped { var padRingRadius: CGFloat { .infinity } }
extension ConsolePillButtonStyle: PadRingShaped { var padRingRadius: CGFloat { .infinity } }
extension ConsolePlayButtonStyle: PadRingShaped {   // 白底胶囊：贴边的奶油框看不见，改外扩 3 pt
    var padRingRadius: CGFloat { .infinity }
    var padRingOutset: CGFloat { 3 }
}
