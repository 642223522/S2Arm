// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI

package enum LauncherCopy {
    /// UI descriptions omit a final full stop; log and data strings keep their original bytes.
    package static func note(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("。") || (value.hasSuffix(".") && !value.hasSuffix("...")) { return String(value.dropLast()) }
        return value
    }
}

/// The Home palette and typeface, with one scale for every utility page and sheet.
package enum LauncherTheme {
    package enum Space {
        package static let xSmall: CGFloat = 4
        package static let small: CGFloat = 8
        package static let medium: CGFloat = 12
        package static let large: CGFloat = 16
        package static let xLarge: CGFloat = 20
        package static let section: CGFloat = 24
        package static let page: CGFloat = 32
    }
    package enum Metrics {
        package static let settingsWidth: CGFloat = 820
        package static let formWidth: CGFloat = 680
        package static let compactWidth: CGFloat = 560
        package static let settingsHeight: CGFloat = 700
        package static let readingPaneHeight: CGFloat = 320
        package static let readingPaneMinHeight: CGFloat = 80
        package static let cardRadius: CGFloat = 16
        package static let cardInset: CGFloat = Space.xLarge
        package static let controlRadius: CGFloat = 10
        package static let controlHeight: CGFloat = 36
        package static let prominentControlHeight: CGFloat = 48
        package static let controlWidth: CGFloat = 220
        package static let compactChoiceWidth: CGFloat = 124
        package static let switchWidth: CGFloat = 40
        package static let switchHeight: CGFloat = 24
        package static let navigationWidth: CGFloat = 300
        package static let libraryInset: CGFloat = 48
        package static let actionMinWidth: CGFloat = 80
        package static let icon: CGFloat = 18
    }
    package enum TypeStyle {
        package static let title = Font.manrope(26, .heavy)
        package static let panelTitle = Font.manrope(18, .bold)
        package static let section = Font.manrope(14, .semibold)
        package static let body = Font.manrope(14)
        package static let detail = Font.manrope(13)
        package static let caption = Font.manrope(12)
        package static let button = Font.manrope(13, .semibold)
    }
    package enum Colors {
        package static let text = Color.white.opacity(0.94)
        package static let secondary = Color.white.opacity(0.65)
        package static let border = Color.white.opacity(0.10)
        package static let card = Color.white.opacity(0.045)
        package static let control = Color.white.opacity(0.065)
        package static let hover = Color.white.opacity(0.11)
        package static let pressed = Color.white.opacity(0.15)
    }
}

package enum LauncherSheetSize {
    case settings, form, compact
    package var width: CGFloat {
        switch self {
        case .settings: return LauncherTheme.Metrics.settingsWidth
        case .form: return LauncherTheme.Metrics.formWidth
        case .compact: return LauncherTheme.Metrics.compactWidth
        }
    }
    package func fitted(to screen: CGSize, height: CGFloat?) -> (width: CGFloat, height: CGFloat?) {
        (min(width, screen.width - 64), height.map { min($0, screen.height - 100) })
    }
}

extension View {
    /// One native material at the window level; content cards only add a light tonal separation.
    package func launcherSheet(_ size: LauncherSheetSize = .settings, height: CGFloat? = LauncherTheme.Metrics.settingsHeight) -> some View {
        modifier(LauncherSheetPresentation(size: size, height: height))
    }

    package func launcherPanel() -> some View {
        background(LauncherTheme.Colors.card, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(LauncherTheme.Colors.border))
    }
}

private struct LauncherSheetPresentation: ViewModifier {
    let size: LauncherSheetSize
    let height: CGFloat?
    func body(content: Content) -> some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let dimensions = size.fitted(to: screen, height: height)
        let page = content
            .frame(width: dimensions.width, height: dimensions.height)
            .frame(maxHeight: screen.height - 100)
            .background(.regularMaterial)
            .font(LauncherTheme.TypeStyle.detail)
            .foregroundStyle(LauncherTheme.Colors.text)
            .preferredColorScheme(.dark)
            .tint(LauncherPalette.cream)
            .labelStyle(LauncherLabelStyle())
            .launcherDropdownHost()
        if #available(macOS 13.3, *) {
            page.presentationBackground(.regularMaterial)
        } else {
            page
        }
    }
}

/// A standard, accessible material respects Reduce Transparency and Increase Contrast.
package struct LauncherWindowMaterial: View {
    package init() {}
    package var body: some View { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
}

/// Window and page subtitles follow their title on one shared text baseline.
package struct LauncherHeadingLine<Title: View, Subtitle: View>: View {
    let title: Title
    let subtitle: Subtitle
    package init(@ViewBuilder title: () -> Title, @ViewBuilder subtitle: () -> Subtitle) {
        self.title = title(); self.subtitle = subtitle()
    }
    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LauncherTheme.Space.medium) {
            title.lineLimit(1).truncationMode(.tail)
            subtitle.lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

package struct LauncherSheetHeading: View {
    let title: String
    let subtitle: String
    let note: String
    package init(_ title: String, subtitle: String = "", note: String = "") {
        self.title = title; self.subtitle = subtitle; self.note = note
    }
    package var body: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Space.small) {
            LauncherHeadingLine {
                Text(title).font(LauncherTheme.TypeStyle.title).tracking(-0.6).accessibilityAddTraits(.isHeader)
            } subtitle: {
                if !subtitle.isEmpty {
                    Text(subtitle).font(LauncherTheme.TypeStyle.body).foregroundStyle(.secondary).help(subtitle)
                }
            }
            if !note.isEmpty {
                Text(LauncherCopy.note(note)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

package struct LauncherSheetFooter<Content: View>: View {
    let content: Content
    package init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    package var body: some View {
        HStack(spacing: LauncherTheme.Space.medium) { content }
            .padding(.horizontal, LauncherTheme.Space.page).padding(.vertical, LauncherTheme.Space.large)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(LauncherTheme.Colors.border).frame(height: 1) }
    }
}

/// Short explanations use their natural height; long ones scroll without displacing the actions.
package struct LauncherReadingPane<Content: View>: View {
    let content: Content
    @State private var contentHeight = LauncherTheme.Metrics.readingPaneHeight
    package init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    package var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: LauncherReadingHeight.self, value: geometry.size.height)
                })
        }
        .frame(minHeight: min(contentHeight, LauncherTheme.Metrics.readingPaneMinHeight),
               idealHeight: min(contentHeight, LauncherTheme.Metrics.readingPaneHeight),
               maxHeight: min(contentHeight, LauncherTheme.Metrics.readingPaneHeight))
        .onPreferenceChange(LauncherReadingHeight.self) { if $0 > 0 { contentHeight = $0 } }
    }
}

private struct LauncherReadingHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Two short actions share one trailing column instead of each consuming a whole column.
package struct LauncherRowActions<Content: View>: View {
    let content: Content
    package init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    package var body: some View {
        HStack(spacing: LauncherTheme.Space.small) { content }
            .environment(\.launcherControlWidth, (LauncherTheme.Metrics.controlWidth - LauncherTheme.Space.small) / 2)
            .frame(width: LauncherTheme.Metrics.controlWidth)
    }
}

/// Symbols of different intrinsic widths occupy an equal slot and share the text's visual centre.
package struct LauncherLabelStyle: LabelStyle {
    package init() {}
    package func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: LauncherTheme.Space.small) {
            configuration.icon.frame(width: LauncherTheme.Metrics.icon, height: LauncherTheme.Metrics.icon)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

package struct LauncherPrimaryButtonStyle: ButtonStyle {
    package init(fill: Bool = false, prominent: Bool = false) { self.fill = fill; self.prominent = prominent }
    package var fill = false
    package var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.launcherControlWidth) private var width
    @State private var hovered = false
    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .manrope(16, .semibold) : LauncherTheme.TypeStyle.button).labelStyle(LauncherLabelStyle())
            .lineLimit(1).minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, LauncherTheme.Space.large)
            .frame(width: width, height: prominent ? LauncherTheme.Metrics.prominentControlHeight : LauncherTheme.Metrics.controlHeight)
            .frame(minWidth: width == nil ? LauncherTheme.Metrics.actionMinWidth : nil)
            .frame(maxWidth: fill ? .infinity : nil)
            .foregroundStyle(LauncherPalette.background)
            .background(LauncherPalette.cream.opacity(configuration.isPressed ? 0.8 : hovered ? 0.93 : 1),
                        in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

package struct LauncherTextFieldStyle: TextFieldStyle {
    package init() {}
    package func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).modifier(LauncherFocusableField())
    }
}

private struct LauncherFocusableField: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).modifier(LauncherFieldChrome(focused: focused))
    }
}

private struct LauncherFieldChrome: ViewModifier {
    var focused = false
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, LauncherTheme.Space.medium)
            .frame(minHeight: LauncherTheme.Metrics.controlHeight)
            .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius)
                .strokeBorder(focused ? LauncherPalette.cream.opacity(0.8) : LauncherTheme.Colors.border, lineWidth: focused ? 1.5 : 1))
            .opacity(enabled ? 1 : 0.55)
    }
}

package struct LauncherSearchField: View {
    let title: String
    let clearTitle: String
    @Binding var text: String
    @FocusState private var focused: Bool
    package init(_ title: String, text: Binding<String>, clearTitle: String) {
        self.title = title; self._text = text; self.clearTitle = clearTitle
    }
    package var body: some View {
        HStack(spacing: LauncherTheme.Space.small) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .frame(width: LauncherTheme.Metrics.icon).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(title).foregroundColor(LauncherTheme.Colors.secondary))
                .textFieldStyle(.plain).focused($focused).accessibilityLabel(title)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .controllerButtonStyle(.plain).accessibilityLabel(clearTitle)
            }
        }
        .font(LauncherTheme.TypeStyle.detail).modifier(LauncherFieldChrome(focused: focused))
    }
}

package struct LauncherIconButtonStyle: ButtonStyle {
    package init() {}
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    package func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .frame(width: LauncherControl.height, height: LauncherControl.height)
            .background(configuration.isPressed ? LauncherTheme.Colors.pressed : hovered ? LauncherTheme.Colors.hover : LauncherTheme.Colors.control,
                        in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius).strokeBorder(LauncherTheme.Colors.border))
            .contentShape(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius))
            .opacity(enabled ? 1 : 0.45).onHover { hovered = $0 }
    }
}

package struct LauncherGuideStep: View {
    let number: Int
    let text: String
    package init(_ number: Int, _ text: String) { self.number = number; self.text = text }
    package var body: some View {
        HStack(alignment: .top, spacing: LauncherTheme.Space.medium) {
            Text(String(number)).font(.manrope(11, .semibold)).foregroundStyle(LauncherPalette.cream)
                .frame(width: 22, height: 22).background(LauncherTheme.Colors.control, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 手柄焦点框画在控件自己的边框上：各样式报自己的圆角
extension LauncherPrimaryButtonStyle: PadRingShaped {   // 奶油底：贴边的奶油框看不见，改外扩 3 pt、同心圆角
    package var padRingRadius: CGFloat { LauncherTheme.Metrics.controlRadius }
    package var padRingOutset: CGFloat { 3 }
}
extension LauncherIconButtonStyle: PadRingShaped { package var padRingRadius: CGFloat { LauncherTheme.Metrics.controlRadius } }
