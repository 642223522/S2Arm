// UI synchronized from LumaNX 8872342 (MIT).
import SwiftUI
import AppKit

enum WorkspacePalette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.86, blue: 0.85, alpha: 1)
            : NSColor(red: 0.02, green: 0.45, blue: 0.49, alpha: 1)
    })
}

/// One density for utility pages and sheets; controller diagrams keep their readable scale.
enum WorkspaceLayout {
    static let pageWidth:CGFloat = 820
    static let pageInset:CGFloat = 16
    static let sectionSpacing:CGFloat = 12
    static let cardInset:CGFloat = 12
    static let contentSpacing:CGFloat = 8
    static let cardRadius:CGFloat = 14
}

struct WorkspacePage<Content: View>: View {
    var maxWidth:CGFloat = WorkspaceLayout.pageWidth
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            PlatformGlassContainer(spacing: WorkspaceLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) { content }
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(WorkspaceLayout.pageInset)
            }
        }.tint(WorkspacePalette.accent).controlSize(.small)
    }
}

struct WorkspaceHeading<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size:16,weight:.medium)).foregroundStyle(WorkspacePalette.accent)
                .frame(width: 32, height: 32).glassSurface(10)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.headline).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(L(subtitle)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            actions.controlSize(.small)
        }
    }
}

struct GlassPanel<Content: View>: View {
    var title: String? = nil
    var symbol: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.contentSpacing) {
            if let title {
                Label(L(title), systemImage: symbol).font(.headline)
            }
            content
        }.padding(WorkspaceLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(WorkspaceLayout.cardRadius)
    }
}

/// Native disclosure semantics and keyboard support, with one compact summary row.
struct CompactDisclosure<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var symbol: String = "info.circle"
    @State private var expanded = false
    @ViewBuilder var content: Content
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: WorkspaceLayout.contentSpacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(WorkspacePalette.accent).frame(width: 20)
                Text(L(title)).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if !subtitle.isEmpty {
                    Text(L(subtitle)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }.padding(.vertical, 2)
        }.tint(WorkspacePalette.accent).disclosureGroupStyle(GlassDisclosureStyle())
    }
}

struct GlassDisclosureStyle:DisclosureGroupStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:0) {
            Button {withAnimation(.easeInOut(duration:0.18)){configuration.isExpanded.toggle()}} label:{
                HStack(spacing:10) {
                    configuration.label.frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }.padding(.vertical,4).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? L("已展开") : L("已折叠"))
            if configuration.isExpanded {configuration.content.frame(maxWidth:.infinity,alignment:.leading)}
        }
    }
}

struct InlineGlassDisclosureStyle<Actions:View>:DisclosureGroupStyle {
    var controlSize:ControlSize = .small
    @ViewBuilder var actions:Actions
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:8) {
            PlatformGlassContainer(spacing:8) {
                HStack(spacing:8) {
                    Button {withAnimation(.easeInOut(duration:0.18)){configuration.isExpanded.toggle()}} label:{
                        HStack(spacing:5) {
                            Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold))
                                .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            configuration.label
                        }
                    }.accessibilityValue(configuration.isExpanded ? L("已展开") : L("已折叠"))
                    actions
                }.platformButtonStyle().controlSize(controlSize)
            }
            if configuration.isExpanded {configuration.content.frame(maxWidth:.infinity,alignment:.leading)}
        }
    }
}

struct StatusPill: View {
    let title: String
    var symbol: String = "checkmark.circle.fill"
    var color: Color = WorkspacePalette.accent
    var body: some View {
        Label(L(title), systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.09), in: Capsule())
    }
}
