// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher

struct ControllerFaceMappingEditor: View {
    @ObservedObject var store: ControllerFaceMapStore
    let family: ControllerFaceFamily
    let simplifiedChinese: Bool
    private var zh: Bool { simplifiedChinese }
    private var mapping: ControllerFaceMapping { store.mapping(for: family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(zh ? "四键布局" : "Button layout").font(.manrope(15, .semibold))
            Text(family == .nintendo ? (zh ? "所有 Switch Pro / Joy-Con 手柄共用" : "Shared by all Switch Pro / Joy-Con controllers")
                : zh ? "所有非 Switch Pro / Joy-Con 手柄共用" : "Shared by all controllers except Switch Pro / Joy-Con")
                .font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(zh ? "实体按键 → Switch" : "Physical button → Switch")
                .font(.manrope(12)).foregroundStyle(.secondary)
            let positions = family.diamond
            VStack(spacing: 2) {
                binding(positions[0])
                HStack(spacing: 8) { binding(positions[1]); Spacer(minLength: 0); binding(positions[3]) }
                binding(positions[2])
            }.frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if family == .nintendo {
                    Button(zh ? "Xbox 位置布局" : "Xbox positions") { store.set(.xboxPosition(for: family), for: family) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true)).controllerID("controller.face.xbox")
                } else {
                    Button(zh ? "Switch 位置布局" : "Switch positions") { store.set(.switchPosition(for: family), for: family) }
                        .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true)).controllerID("controller.face.switch")
                }
                Button(zh ? "恢复默认" : "Reset") { store.set(nil, for: family) }
                    .controllerButtonStyle(LauncherSecondaryButtonStyle(fill: true)).controllerID("controller.face.reset")
            }
            Text(zh ? "游戏内长按 L3 + R3 1 秒查看对照" : "In game, hold L3 + R3 for 1 second to view the map")
                .font(.manrope(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = store.problem {
                Text((zh ? "键位未能保存或读取：" : "Could not save or read buttons: ") + problem)
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("controller.face-mapping")
    }
    private func binding(_ source: Int) -> some View {
        HStack(spacing: 6) {
            ControllerFaceButton(family: family, source: source)
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
            LauncherDropdown(options: ControllerFaceMapping.labels.enumerated().map { (String($0.offset), $0.element) },
                selection: String(mapping.target(for: source)), label: family.label(source: source), fill: true,
                artwork: { value in AnyView(ControllerFaceButton(family: .nintendo, source: Int(value) ?? 0, size: 30)) }) { target in
                if let target = Int(target) { store.set(mapping.assigning(source: source, to: target), for: family) }
            }.frame(width: 88).controllerID("controller.face.\(source)")
        }.frame(width: 146)
    }
}
