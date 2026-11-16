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

struct ConsolePlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 92, height: 56)
            .foregroundStyle(.black.opacity(0.85))
            .background(.white.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hovered ? 1 : 0), lineWidth: 2).padding(-4))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}

// 圆钮 / 胶囊：焦点框跟着画成圆 / 胶囊
extension ConsoleIconButtonStyle: PadRingShaped { var padRingRadius: CGFloat { .infinity } }
extension ConsolePlayButtonStyle: PadRingShaped {   // 白底胶囊：贴边的奶油框看不见，改外扩 3 pt
    var padRingRadius: CGFloat { .infinity }
    var padRingOutset: CGFloat { 3 }
}
