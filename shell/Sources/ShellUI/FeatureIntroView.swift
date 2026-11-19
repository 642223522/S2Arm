#if !os(tvOS)   // S2Arm（不是上游文件）：iPhone 上的新功能介绍（0.6.0 起，11-19 维护者定：iPhone 只放两页，和电脑共用 docs/site/feature.json 与图）
import SwiftUI

/// "What's new" on iPhone: one page per feature, the picture on top, then the kicker, the title and the three short columns
/// (what it is / how to use it / where, or the page's own headings such as "Good to know"). Swipe or Next to turn the page;
/// the last page's button and the close button both end it (it counts as seen). The same pages as the computer's window.
public struct FeatureIntroView: View {
    let intro: FeatureIntro
    /// The page shown; the host binds it so a controller turns the pages too (left / right, A next, B close).
    @Binding var index: Int
    let close: () -> Void
    public init(intro: FeatureIntro, index: Binding<Int>, close: @escaping () -> Void) { self.intro = intro; _index = index; self.close = close }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $index) {
                ForEach(intro.pages.indices, id: \.self) { i in
                    page(intro.pages[i]).tag(i)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(ShellPalette.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain).padding(16)
            .accessibilityLabel(ShellStrings.text("Close")).accessibilityIdentifier("featureIntro.close")
        }
        .accessibilityIdentifier("featureIntro")
    }

    private func page(_ p: FeatureIntro.Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let picture = p.picture { Image(decorative: picture.image, scale: 1).resizable().scaledToFill() }
                        else { ShellPalette.surface }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text(intro.badge).shellText(12, .bold).foregroundStyle(ShellPalette.cream)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule()).padding(16)
                    }
                VStack(alignment: .leading, spacing: 12) {
                    Text(p.kicker).shellText(12.5, .bold).foregroundStyle(ShellPalette.attention)
                    Text(p.title).shellText(24, .heavy).fixedSize(horizontal: false, vertical: true)
                    column(p.labels["what"] ?? ShellStrings.text("What it is"), p.what)
                    column(p.labels["how"] ?? ShellStrings.text("How to use it"), p.how)
                    column(p.labels["where"] ?? ShellStrings.text("Where to find it"), p.whereText)
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func column(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).shellText(12, .bold).foregroundStyle(ShellPalette.attention)
            Text((try? AttributedString(markdown: body)) ?? AttributedString(body)).shellText(14.5)
                .foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        let last = index >= intro.pages.count - 1
        return HStack(spacing: 7) {
            ForEach(intro.pages.indices, id: \.self) { i in
                Capsule().fill(i == index ? ShellPalette.cream : .white.opacity(0.2)).frame(width: i == index ? 22 : 8, height: 8)
            }
            Spacer()
            Button {
                if last { close() } else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { index += 1 } }
            } label: {
                Text(last ? ShellStrings.text("Start playing") : ShellStrings.text("Next"))
            }
            .buttonStyle(PrimaryPillStyle())
            .accessibilityIdentifier("featureIntro.next")
        }
    }
}
#endif
