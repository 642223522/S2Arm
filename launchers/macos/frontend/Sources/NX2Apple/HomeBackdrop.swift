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
                    .init(color: .black.opacity(0.62), location: 0),
                    .init(color: .black.opacity(0.32), location: 0.18),
                    .init(color: .black.opacity(0.08), location: 0.42),
                    .init(color: .black.opacity(0.30), location: 0.62),
                    .init(color: .black.opacity(0.88), location: 1)
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
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(size: CGSize) -> some View {
        // Try decoding each source independently: an unavailable banner must not hide a valid cover.
        // 玩家自己换过封面：大图也用玩家的封面（主线游戏库同一规则，玩家的选择优先于自带横幅）
        if let custom = game?.customCover == true ? covers.image(game?.cover) : nil {
            CoverFill(image: custom).frame(width: size.width, height: size.height)
        } else if let banner = covers.image(game?.banner) {
            CoverFill(image: Self.trimBannerLetterbox(banner)).frame(width: size.width, height: size.height)
        } else if let cover = covers.image(game?.cover) {
            CoverFill(image: cover).frame(width: size.width, height: size.height)
        } else {
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.3), LauncherPalette.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }

    private static let trimmedCache: NSCache<NSImage, NSImage> = {
        let c = NSCache<NSImage, NSImage>()
        c.countLimit = 32
        return c
    }()

    /// 部分游戏自带横幅底部带有纯灰/纯黑留边（如 1920x1080 底部 80px 灰条），裁掉纯色边缘条以保证壁纸真正铺满窗口。
    static func trimBannerLetterbox(_ image: NSImage) -> NSImage {
        if let cached = trimmedCache.object(forKey: image) { return cached }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        guard w >= 64, h >= 64 else { return image }
        let rep = NSBitmapImageRep(cgImage: cg)
        let maxTrim = Int(Double(h) * 0.18)
        let xs = [w / 8, w / 4, w / 2, (w * 3) / 4, (w * 7) / 8]
        func isMonochromeRow(_ y: Int) -> Bool {
            var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0
            for (idx, x) in xs.enumerated() {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if abs(r - g) > 0.03 || abs(g - b) > 0.03 { return false }
                if idx == 0 { r0 = r; g0 = g; b0 = b }
                else if abs(r - r0) > 0.03 || abs(g - g0) > 0.03 || abs(b - b0) > 0.03 { return false }
            }
            return true
        }
        var trimBottom = 0
        for y in stride(from: h - 1, through: max(0, h - maxTrim), by: -1) {
            if isMonochromeRow(y) { trimBottom += 1 } else { break }
        }
        let result: NSImage
        if trimBottom > 4, trimBottom < maxTrim, let cropped = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h - trimBottom)) {
            result = NSImage(cgImage: cropped, size: NSSize(width: w, height: h - trimBottom))
        } else {
            result = image
        }
        trimmedCache.setObject(result, forKey: image)
        return result
    }
}
