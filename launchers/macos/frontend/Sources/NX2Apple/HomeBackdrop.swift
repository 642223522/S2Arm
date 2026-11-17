// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher
import S2ArmAppleAdapter

/// The banner is the default artwork; a cover the player customized takes precedence (the player's choice wins).
struct HomeBackdrop: View {
    let game: GameSummary?
    @ObservedObject var covers: CoverCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LauncherPalette.background
                artwork(size: geometry.size)
                    .id(game?.id)
                    .transition(.opacity)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.65), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.38),
                    .init(color: .clear, location: 0.75)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.35),
                    .init(color: .black.opacity(0.28), location: 0.6),
                    .init(color: .black.opacity(0.85), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topTrailing) {
                // 柔和暗角衬出无底色的标题栏图标，浅色海报也能看清。
                RadialGradient(colors: [.black.opacity(0.38), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 360)
                    .frame(width: 360, height: 360)
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: game?.id)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(size: CGSize) -> some View {
        // Try decoding each source independently: an unavailable banner must not hide a valid cover.
        // 玩家自己换过封面：大图也用玩家的封面（主线游戏库同一规则，玩家的选择优先于自带横幅）
        if let image = (game?.customCover == true ? covers.image(game?.cover) : nil) ?? covers.image(game?.banner) ?? covers.image(game?.cover) {
            CoverFill(image: image).frame(width: size.width, height: size.height)
        } else {
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.3), LauncherPalette.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }
}
