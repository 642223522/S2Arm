// Derived from NX2Apple (MIT; see frontend/NOTICE).
// S2Arm: shared theme spacing and typography; inline page subtitles; card actions participate in controller navigation.
import SwiftUI
import AppKit
import NXCore
import NXModel

// The pieces every card of the Builds and Settings pages is made of: a titled group, a row, a divider, a disclosure row.
// They are the library's and the launch options' look (LNPANDY/NX2Apple#387, step 8).

extension StepState {
    package var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }
}

/// The big title of a page with an inline subtitle.
package struct CardPageHeading: View {
    let title: String
    let note: String

    package init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    package var body: some View {
        LauncherHeadingLine {
            Text(title).font(.manrope(44, .heavy)).tracking(-1.3)
        } subtitle: {
            Text(note).font(.manrope(15)).foregroundStyle(.secondary).help(note)
        }
    }
}

/// A titled group: a small tracked label over one card of rows.
package struct CardGroup<Content: View>: View {
    let label: String
    let footnote: String
    let content: Content

    package init(_ label: String, footnote: String = "", @ViewBuilder _ content: () -> Content) {
        self.label = label
        self.footnote = footnote
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(LauncherTheme.TypeStyle.section).foregroundStyle(.secondary)
                .padding(.leading, LauncherTheme.Metrics.cardInset)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .launcherPanel()
            if !footnote.isEmpty {
                Text(LauncherCopy.note(footnote)).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, LauncherTheme.Metrics.cardInset)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A card row: title, optional status/disclosure indicator, description, and one trailing control column.
/// Rows without status indicators keep the full reading width instead of reserving an empty icon slot.
/// Its buttons and dropdowns are all LauncherControl.width wide, so they line up in one column across the cards.
package struct CardRow<Trailing: View>: View {
    let title: String
    let detail: String
    let detail2: String
    let dot: Color?
    let help: String
    let open: Bool?
    /// 控件另起一行（11-14 体验梳理第二轮）：说明长、右边又有两个按钮时，横排会把说明挤成一条窄栏折五六行
    let stacked: Bool
    let trailing: Trailing

    package init(_ title: String, detail: String = "", detail2: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil,
                 stacked: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.stacked = stacked
        self.title = title
        self.detail = detail
        self.detail2 = detail2
        self.dot = dot
        self.help = help
        self.open = open
        self.trailing = trailing()
    }

    package var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: LauncherTheme.Space.medium) {
                    texts
                    HStack { Spacer(minLength: 0); trailing.launcherRowControls() }
                }
            } else {
                HStack(spacing: LauncherTheme.Space.section) {
                    texts
                    trailing.launcherRowControls()
                }
            }
        }
        .padding(.horizontal, LauncherTheme.Metrics.cardInset).padding(.vertical, LauncherTheme.Space.large)
        .frame(minHeight: 68)
    }

    private var texts: some View {
            VStack(alignment: .leading, spacing: LauncherTheme.Space.xSmall) {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(title).font(LauncherTheme.TypeStyle.body).fixedSize(horizontal: false, vertical: true)
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face, on one line, cut in the middle when
                    // too long. Everything else is prose in Manrope and wraps, so no word is ever cut.
                    if detail.hasPrefix("/") || detail.hasPrefix("~") {
                        PathLink(detail, help: help)
                    } else {
                        Text(LauncherCopy.note(detail)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).help(LauncherCopy.note(help.isEmpty ? detail : help))
                    }
                }
                if !detail2.isEmpty {
                    if detail2.hasPrefix("/") || detail2.hasPrefix("~") { PathLink(detail2) }
                    else { Text(detail2).font(.mono(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A path shown on a card: monospaced, one line, cut in the middle. When it exists on disk it is a link — a click opens the folder
/// in Finder (a file is selected in its folder), so nobody has to copy the path by hand. A path that is not there (a disk not
/// plugged in) stays plain text.
package struct PathLink: View {
    let path: String
    let help: String
    @State private var hovering = false

    package init(_ path: String, help: String = "") { self.path = path; self.help = help }

    private var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    package var body: some View {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let text = Text(path).font(.mono(12)).lineLimit(1).truncationMode(.middle)
        if exists {
            Button {
                if isDir.boolValue { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                text.underline(hovering).foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
            .controllerButtonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(help.isEmpty ? path : help)
            .accessibilityHint(Text(path))
        } else {
            text.foregroundStyle(.secondary).help(help.isEmpty ? path : help)
        }
    }
}

package struct CardDivider: View {
    package init() {}
    package var body: some View {
        Rectangle().fill(LauncherTheme.Colors.border).frame(height: 1)
            .padding(.horizontal, LauncherTheme.Metrics.cardInset).accessibilityHidden(true)
    }
}

/// A row that opens the rows under it.
package struct CardDisclosure: View {
    let title: String
    let detail: String
    let isOpen: Bool
    let toggle: () -> Void

    package init(_ title: String, detail: String = "", isOpen: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isOpen = isOpen
        self.toggle = toggle
    }

    package var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { toggle() } }) {
            CardRow(title, detail: detail, open: isOpen) { EmptyView() }
                .contentShape(Rectangle())
        }
        .controllerButtonStyle(.plain)
    }
}

/// The scrolling column of a page of cards. A controller's focus on one of its `set.` targets scrolls into view.
package struct LauncherPageScroll<Content: View>: View {
    let content: Content
    @EnvironmentObject private var padFocus: PadFocus

    package init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: LauncherTheme.Space.section) { content }
                    .padding(LauncherTheme.Space.page)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
            }
            .onChange(of: padFocus.focused) { id in   // a controller's focus on this page scrolls into view
                if let id, id.hasPrefix("set.") { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .controllerButtonStyle(LauncherSecondaryButtonStyle())
    }
}

package func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
