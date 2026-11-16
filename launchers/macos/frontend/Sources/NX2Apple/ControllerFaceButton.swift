// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI

/// Vector keycaps based on the supplied Joy-Con, DualSense and Xbox photos.
/// Legends sit beneath the cap reflections, rather than inside SF Symbol rings.
struct ControllerFaceButton: View {
    let family: ControllerFaceFamily
    let source: Int
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, bounds in
            var c = context
            c.scaleBy(x: bounds.width / 100, y: bounds.height / 100)
            Self.draw(in: &c, family: family, source: source)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(family.label(source: source))
    }

    private static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private static func disk(_ inset: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: inset, y: inset, width: 100 - 2 * inset, height: 100 - 2 * inset))
    }

    private static func draw(in c: inout GraphicsContext, family: ControllerFaceFamily, source: Int) {
        let ps = family == .playstation, xbox = family == .xbox
        var socket = c
        socket.addFilter(.shadow(color: .black.opacity(0.65), radius: 3, x: 0, y: 3))
        socket.fill(disk(5), with: .color(color(0x090b0d)))

        // A dark socket and a narrow bevel separate the cap from the panel.
        c.fill(disk(6), with: .linearGradient(Gradient(colors: ps
            ? [color(0x3b4144), color(0xa6adb0), color(0x313639), color(0x8a9093)]
            : [color(0x62696c), color(0x16191b), color(0x020304), color(0x343a3e)]),
            startPoint: CGPoint(x: 10, y: 4), endPoint: CGPoint(x: 85, y: 96)))

        let cap = disk(ps ? 12 : 10)
        c.fill(cap, with: .linearGradient(Gradient(colors: ps
            ? [color(0xf1f4f4), color(0xd8dfe1), color(0xc0c8cc), color(0xe6e9e9)]
            : xbox ? [color(0x363b3e), color(0x101416), color(0x030506), color(0x15191b)]
            : [color(0x363a40), color(0x1b1f25), color(0x090d12), color(0x15191e)]),
            startPoint: CGPoint(x: 24, y: 9), endPoint: CGPoint(x: 67, y: 94)))

        var face = c
        face.clip(to: cap)
        face.fill(cap, with: .radialGradient(Gradient(colors: [.white.opacity(ps ? 0.35 : 0.09), .clear]),
            center: CGPoint(x: 31, y: 22), startRadius: 0, endRadius: 66))

        if ps {
            let symbol = playstationSymbol(source)
            var etching = face
            etching.translateBy(x: 0, y: 1)
            etching.stroke(symbol, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 4.8, lineCap: .square, lineJoin: .miter))
            face.stroke(symbol, with: .color(color(0x92999d)), style: StrokeStyle(lineWidth: 4.6, lineCap: .square, lineJoin: .miter))
        } else {
            let ink: Color = xbox ? [color(0xa8d62f), color(0xeb5943), color(0x43addc), color(0xe5d738)][source]
                : family == .nintendo ? color(0xa3a9b2) : color(0xe0e4e8)
            let font = Font.custom(xbox ? "HelveticaNeue-Medium" : "HelveticaNeue", size: xbox ? 65 : 51)
            let letter = Text(ControllerFaceMapping.labels[source]).font(font)
            face.draw(letter.foregroundColor(.black.opacity(0.5)), at: CGPoint(x: 50, y: 53))
            face.draw(letter.foregroundColor(ink), at: CGPoint(x: 50, y: 51))
        }

        // A clear DualSense rim, a glossy Xbox dome, and a softer Joy-Con sheen.
        let shine: Double = ps ? 0.52 : xbox ? 0.58 : 0.17
        face.fill(Path(ellipseIn: CGRect(x: 19, y: 10, width: 49, height: 29)),
            with: .linearGradient(Gradient(colors: [.white.opacity(shine), .white.opacity(0)]),
                startPoint: CGPoint(x: 30, y: 12), endPoint: CGPoint(x: 43, y: 39)))
        if ps || xbox {
            face.fill(Path(ellipseIn: CGRect(x: 26, y: 14, width: 15, height: 8)),
                with: .radialGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0)]),
                    center: CGPoint(x: 33, y: 18), startRadius: 0, endRadius: 9))
        }
        var lowerReflection = Path()
        lowerReflection.move(to: CGPoint(x: 18, y: 69))
        lowerReflection.addCurve(to: CGPoint(x: 73, y: 85), control1: CGPoint(x: 30, y: 94), control2: CGPoint(x: 56, y: 96))
        c.stroke(lowerReflection, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(ps ? 0.85 : xbox ? 0.38 : 0.1), .clear]),
            startPoint: CGPoint(x: 18, y: 72), endPoint: CGPoint(x: 76, y: 91)),
            style: StrokeStyle(lineWidth: ps ? 2.2 : 1.4, lineCap: .round))
        c.stroke(disk(ps ? 10 : 8), with: .linearGradient(Gradient(colors: [.white.opacity(ps ? 0.7 : 0.2), .clear, .black.opacity(0.6)]),
            startPoint: CGPoint(x: 20, y: 9), endPoint: CGPoint(x: 80, y: 94)), lineWidth: 1)
    }

    private static func playstationSymbol(_ source: Int) -> Path {
        var path = Path()
        switch source {
        case 0:
            path.move(to: CGPoint(x: 31, y: 31)); path.addLine(to: CGPoint(x: 69, y: 69))
            path.move(to: CGPoint(x: 69, y: 31)); path.addLine(to: CGPoint(x: 31, y: 69))
        case 1: path.addEllipse(in: CGRect(x: 26, y: 26, width: 48, height: 48))
        case 2: path.addRect(CGRect(x: 29, y: 29, width: 42, height: 42))
        default:
            path.move(to: CGPoint(x: 50, y: 25)); path.addLine(to: CGPoint(x: 75, y: 68))
            path.addLine(to: CGPoint(x: 25, y: 68)); path.closeSubpath()
        }
        return path
    }
}
