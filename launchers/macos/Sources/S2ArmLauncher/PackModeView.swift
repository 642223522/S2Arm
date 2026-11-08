// #377：一键出包的进度阶段条与结束页画面模式。
import SwiftUI

/// 「解包 → 改写与准备 → 直连库 → 编 App 与签名」。
struct PackStageStrip: View {
    let task: TaskRecord
    var body: some View {
        let groups = PackStagePlan.groups(for: task)
        // 卡片标题已写「打 iPhone 包」，不再单起一行「出包进度」
        HStack(alignment:.top, spacing:6) {
            ForEach(groups) { group in
                PackStageGroupView(group: group)
                if group.id != groups.last?.id {
                    Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top,6)
                }
            }
        }.accessibilityElement(children:.combine)
    }
}

private struct PackStageGroupView: View {
    let group: PackStageGroup
    var body: some View {
        VStack(alignment:.leading, spacing:5) {
            ForEach(group.phases) { phase in PackStageLane(phase: phase) }
        }.frame(maxWidth:.infinity, alignment:.leading).frame(minHeight:40, alignment:.topLeading)
    }
}

private struct PackStageLane: View {
    let phase: PackStagePhase
    private var tint: Color {
        switch phase.state {
        case .done, .running: return .teal
        case .pending: return .secondary
        case .unused: return .orange
        }
    }
    private var stateText: String {
        switch phase.state {
        case .done: return L("完成")
        case .running: return L("进行中")
        case .pending: return L("等待")
        case .unused: return L("未出")
        }
    }
    private var unusedReason: String? {
        if case .unused(let reason) = phase.state { return reason }
        return nil
    }
    private var spoken: String {
        var parts: [String] = [L(phase.label), stateText]
        if let detail = phase.detail, !detail.isEmpty { parts.append(SharedExperience.stageLabel(detail)) }
        if let reason = unusedReason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment:.leading, spacing:3) {
            HStack(spacing:4) {
                Text(L(phase.label)).font(.caption2.weight(.medium)).lineLimit(1)
                Spacer(minLength:2)
                Text(stateText).font(.caption2).foregroundStyle(tint).fixedSize()
            }
            GeometryReader { geometry in
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint).frame(width: geometry.size.width * phase.fill)
                }
            }.frame(height:4)
        }
        .modifier(HelpTip(text: unusedReason))
        // 正在做的子步骤（detail）卡片下一行「第 x/y 步」已写，条上不重复显示，只给读屏
        .accessibilityLabel(spoken)
    }
}

/// 有原因才挂 tooltip，空串不生成空提示框
private struct HelpTip: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.help(text) } else { content }
    }
}

/// 结束页：这一包的画面模式（取自 IPA 的 Info.plist）。
struct PackModeCard: View {
    let mode: PackGraphicsMode
    private var symbol: String {
        switch mode {
        case .direct: return "bolt.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private var tint: Color {
        switch mode {
        case .direct: return .teal
        case .unknown: return .secondary
        }
    }
    private var value: String { mode.title }
    var body: some View {
        VStack(alignment:.leading, spacing:6) {
            HStack(alignment:.firstTextBaseline, spacing:6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(L("画面模式")).font(.callout.bold())
                Text(value).font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .fixedSize(horizontal:false, vertical:true).textSelection(.enabled)
                Spacer(minLength:0)
            }
            if case .direct = mode {
                Text(L("这一包带直连库，通用着色器仍作兜底：直连崩溃或画面异常时退回通用。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth:.infinity, alignment:.leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine)
    }
}
