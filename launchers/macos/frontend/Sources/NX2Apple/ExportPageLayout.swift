// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher

/// Shared page margins and fixed footer for export setup, progress and results.
struct ExportPageLayout<Content: View, Actions: View>: View {
    let content: Content
    let actions: Actions

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content(); self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, LauncherTheme.Metrics.libraryInset)
                    .padding(.top, 22).padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.3)
            actions
                .padding(.horizontal, LauncherTheme.Metrics.libraryInset).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
    }
}
