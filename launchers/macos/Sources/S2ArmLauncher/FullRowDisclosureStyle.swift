import SwiftUI

// Only the header toggles: controls inside expanded content retain their own actions.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    var cardPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(cardPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? L("已展开") : L("已收起"))
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, cardPadding == 0 ? 16 : cardPadding)
                    .padding(.trailing, cardPadding)
                    .padding(.bottom, cardPadding)
            }
        }
    }
}
