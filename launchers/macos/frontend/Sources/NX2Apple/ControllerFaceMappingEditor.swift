// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher

struct ControllerFaceMappingEditor: View {
    @ObservedObject var store: ControllerFaceMapStore
    let family: ControllerFaceFamily
    let lang: String   // 界面语言代码（Lang.code），文案走 l10n 的 s2arm.controller.faceMap.*
    private func t(_ key: String) -> String { NS2LauncherController.text("s2arm.controller.faceMap." + key, lang) }
    private var mapping: ControllerFaceMapping { store.mapping(for: family) }

    /// 「四键布局」选单：默认（照键上字母）、另一种常见布局（非任天堂手柄 = Switch 布局右键确认；任天堂手柄 = Xbox 布局下键确认）、
    ///   自定义。自定义不是一种排列：四键不等于前两种时自动显示成它；选它本身不改键位
    private var presets: [(value: String, mapping: ControllerFaceMapping)] {
        [("default", .identity), family == .nintendo ? ("xbox", .xboxPosition(for: family)) : ("switch", .switchPosition(for: family))]
    }
    private var layoutSelection: String { presets.first { $0.mapping == mapping }?.value ?? "custom" }

    var body: some View {
        // 由上到下：标题 + 布局选单 → 四键对应 → 说明小字（共用范围、怎么看、游戏内查看，一块放）。区块间距 16，块内 4（4 的倍数）
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(t("title")).font(.manrope(15, .semibold))
                Spacer(minLength: 8)
                LauncherDropdown(options: presets.map { ($0.value, t("layout." + $0.value)) } + [("custom", t("layout.custom"))],
                                 selection: layoutSelection, label: t("title"), fill: true, artwork: nil) { value in
                    if let preset = presets.first(where: { $0.value == value }) { store.set(preset.mapping, for: family) }
                }
                .frame(width: 168).controllerID("controller.face.layout")
            }
            let positions = family.diamond
            VStack(spacing: 4) {
                binding(positions[0])
                HStack(spacing: 8) { binding(positions[1]); Spacer(minLength: 0); binding(positions[3]) }
                binding(positions[2])
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(t("direction"))
                Text(t(family == .nintendo ? "sharedNintendo" : "sharedOther"))
                Text(t("hint"))
                if let problem = store.problem {
                    Text(t("problem").replacingOccurrences(of: "{0}", with: problem)).foregroundStyle(LauncherPalette.danger)
                }
            }
            .font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("controller.face-mapping")
    }
    private func binding(_ source: Int) -> some View {
        HStack(spacing: 8) {
            ControllerFaceButton(family: family, source: source)
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
            LauncherDropdown(options: ControllerFaceMapping.labels.enumerated().map { (String($0.offset), $0.element) },
                selection: String(mapping.target(for: source)), label: family.label(source: source), fill: true,
                artwork: { value in AnyView(ControllerFaceButton(family: .nintendo, source: Int(value) ?? 0, size: 30)) }) { target in
                if let target = Int(target) { store.set(mapping.assigning(source: source, to: target), for: family) }
            }.frame(width: 88).controllerID("controller.face.\(source)")
        }.frame(width: 148)
    }
}
