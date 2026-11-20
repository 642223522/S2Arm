// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Native typing edits the heading in place; controller confirmation opens the
/// shared screen keyboard and commits through the same customization action.
struct ExportNameControl: View {
    let name: String
    let custom: Bool
    let save: (String) -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.padControls) private var registry
    @State private var draft: String
    @State private var editing = false
    @State private var controllerEditing = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    init(name: String, custom: Bool, save: @escaping (String) -> Void) {
        self.name = name; self.custom = custom; self.save = save
        _draft = State(initialValue: name)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The embedded variable face has different idle/editor baselines in
            // AppKit's text cell. The native heading font keeps both states aligned.
            TextField(loc.t("s2arm.custom.name.placeholder"), text: $draft)
                .textFieldStyle(.plain).font(.system(size: 36, weight: .heavy)).tracking(-1.0)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .accessibilityLabel(loc.t("s2arm.custom.name.title"))
                .accessibilityIdentifier("export.name.field")
            Button { focused = true } label: {
                Image(systemName: "pencil").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(focused || hovered ? LauncherPalette.cream : .secondary)
            }.buttonStyle(.plain).accessibilityLabel(loc.t("s2arm.custom.name.help"))
        }
        .onHover { hovered = $0 }
        .controllerControl(id: "export.name", activate: editFromController)
        .help(loc.t("s2arm.custom.name.help"))
        .contextMenu {
            if custom { Button(loc.t("s2arm.custom.name.reset")) { editing = false; focused = false; save("") } }
        }
        .onChange(of: name) { if !editing && !controllerEditing { draft = $0 } }
        .onChange(of: focused) {
            if $0 { editing = true }
            else if !controllerEditing { finish(apply: true) }
        }
    }

    private func finish(apply: Bool) {
        guard editing else { return }
        editing = false; focused = false
        if apply, draft != name { save(draft) }
        else { draft = name }
    }

    private func editFromController() {
        guard let navigation = registry as? LauncherPadNavigation else { return }
        controllerEditing = true; editing = false; focused = false
        navigation.editText(value: draft, label: loc.t("s2arm.custom.name.title"), onClose: { controllerEditing = false }) { value in
            draft = value
            if value != name { save(value) }
        }
    }
}
