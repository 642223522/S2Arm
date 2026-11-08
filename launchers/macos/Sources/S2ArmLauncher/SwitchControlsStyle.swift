import SwiftUI

/// Keep classic Joy-Con hardware colours; surrounding controls use the launcher theme.
enum SwitchControlsPalette {
    static let blue = Color(red:0,green:0.765,blue:0.890)
    static let red = Color(red:1,green:0.271,blue:0.329)
    static let ink = Color(red:0.17,green:0.18,blue:0.20)
    static let focus = WorkspacePalette.accent
    static let focusRing = WorkspacePalette.accent
}

struct SwitchSettingsBackground: View {
    var body: some View {LibraryBackdrop()}
}

extension View {
    func switchSettingsPanel() -> some View {glassSurface(WorkspaceLayout.cardRadius)}
}

struct SwitchSettingsTabs: View {
    @Binding var selection: String
    private let tabs = [("bindings", "可视化改键"), ("list", "完整列表"), ("options", "鼠标与摇杆"), ("test", "输入测试")]
    var body: some View {
        Picker(L("输入映射页面"),selection:$selection) {
            ForEach(tabs,id:\.0) {value,title in Text(L(title)).tag(value)}
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth:600,alignment:.leading)
    }
}

struct SwitchSettingsMenuOption: Identifiable {
    var id: String { title }
    let title: String
    var detail: String? = nil
    var selected = false
    let action: () -> Void
}

/// A native glass button opens a material-backed options panel. Keeping the
/// explicit open action lets key recording stop before menu keyboard navigation.
struct SwitchSettingsMenu: View {
    let title: String
    var compact = false
    var accessibilityTitle: String? = nil
    var onOpen: () -> Void = {}
    let options: [SwitchSettingsMenuOption]
    @State private var expanded = false
    @State private var width: CGFloat = 240
    var body: some View {
        Button { if !expanded { onOpen() }; expanded.toggle() } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: compact ? 16 : 30, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .platformButtonStyle().tint(nil as Color?)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in width = value }
        })
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(title)
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            SwitchSettingsOptions(title: accessibilityTitle ?? title, options: options) { expanded = false }
                .frame(width: max(240, width))
                .presentationBackground(.regularMaterial)
        }
    }
}

private struct SwitchSettingsOptions: View {
    let title: String
    let options: [SwitchSettingsMenuOption]
    let dismiss: () -> Void
    @FocusState private var focused: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 4)
            Divider()
            ScrollViewReader { reader in
              ScrollView {
                VStack(spacing: 4) {
                    ForEach(options) { option in
                        let highlighted = focused == option.id
                        Button { option.action(); dismiss() } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title).font(.body.weight(option.selected ? .semibold : .regular))
                                    if let detail = option.detail { Text(detail).font(.caption) }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).opacity(option.selected ? 1 : 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .foregroundStyle(Color.primary)
                            .background(highlighted || option.selected ? WorkspacePalette.accent.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:10))
                            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(WorkspacePalette.accent.opacity(highlighted ? 0.45 : 0)).allowsHitTesting(false))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).focusable().focusEffectDisabled().focused($focused, equals: option.id)
                        .accessibilityAddTraits(option.selected ? [.isSelected] : [])
                        .onHover { if $0 { focused = option.id } }
                        .id(option.id)
                    }
                }
              }.scrollBounceBehavior(.basedOnSize)
                .onChange(of: focused) { _, value in if let value { reader.scrollTo(value) } }
            }
        }
        .padding(8).frame(height: min(360, options.reduce(CGFloat(48)) { $0 + ($1.detail == nil ? 40 : 72) }))
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
        .onAppear { focused = options.first(where: \.selected)?.id ?? options.first?.id }
        .onExitCommand(perform: dismiss)
        .onMoveCommand { direction in
            guard !options.isEmpty, direction == .up || direction == .down else { return }
            let current = options.firstIndex { $0.id == focused } ?? 0
            focused = options[(current + (direction == .down ? 1 : options.count - 1)) % options.count].id
        }
        .onKeyPress(.return) {
            guard let option = options.first(where: { $0.id == focused }) else { return .ignored }
            option.action(); dismiss(); return .handled
        }
    }
}
