import SwiftUI
import S2ArmAppleAdapter

// 里程碑进度的时间推算 MilestoneEstimate 在适配层（S2ArmAppleAdapter Milestones.swift，新前端出包进度页同用），单测在 S2ArmAppleAdapterTests。

func durationText(_ s: Double) -> String {
    let f = DateComponentsFormatter(); f.unitsStyle = .short; f.allowedUnits = s >= 3600 ? [.hour, .minute] : s >= 60 ? [.minute, .second] : [.second]
    f.calendar?.locale = Locale(identifier: Localization.language.hasPrefix("en") ? "en_US" : "zh_CN")
    return f.string(from: max(0, s.rounded())) ?? "\(Int(s))"
}

/// 一根分段进度条（每段一个里程碑；全部有本机记录时宽度按记录耗时，否则等宽），下面写当前在做什么、为什么做、已用多久；
/// 只有算得出来时才写还需多久（本步速度 / 本机历史，见 MilestoneEstimate）。showsBar = false：调用方另有阶段条（打 iPhone 包的 PackStageStrip），这里不再画一根。
struct MilestoneProgressView: View {
    let task: TaskRecord
    var compact = false
    var showsBar = true
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let plan = task.milestones ?? []
            let est = MilestoneEstimate(plan: plan, current: task.milestone, started: task.milestoneStarted ?? [:], fraction: task.progressFraction, now: tl.date.timeIntervalSince1970)
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                if showsBar {
                    GeometryReader { g in
                        let weighted = plan.allSatisfy { $0.measured != nil }
                        let weight: (Milestone) -> Double = { weighted ? max($0.measured ?? 1, 1) : 1 }
                        let total = plan.reduce(0) { $0 + weight($1) }
                        let gap = 2.0, usable = max(0, g.size.width - gap * Double(max(0, plan.count - 1)))
                        HStack(spacing: gap) {
                            ForEach(Array(plan.enumerated()), id: \.element.id) { k, m in
                                let w = max(6, usable * weight(m) / max(total, 1))
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.secondary.opacity(0.18))
                                    Rectangle().fill(k == est.index ? Color.teal : Color.teal.opacity(0.75)).frame(width: w * est.fill(k))
                                }.frame(width: w).help("\(k + 1). \(SharedExperience.stageLabel(m.label))：\(L(m.purpose))")
                            }
                        }
                    }.frame(height: compact ? 6 : 10).clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 5))
                }
                if let i = est.index {
                    let m = plan[i]
                    HStack(alignment: .firstTextBaseline) {
                        Text(Localization.language.hasPrefix("en") ? "Step \(i + 1)/\(plan.count)" : "第 \(i + 1)/\(plan.count) 步").foregroundStyle(.secondary)
                        Text(SharedExperience.stageLabel(m.label)).bold()
                        if let d = task.done, let t = task.total, t > 0 {
                            // 字节按 GB / MB 显示（10-23 本机走查：原来是「4,043,309,056 / 9,060,474,368」）；其余单位（支、个）照原数
                            let fmt: (Double) -> String = { task.unit == "B" ? ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file) : "\(Int($0))" }
                            Text("\(fmt(d)) / \(fmt(t)) · \(Int((est.fraction ?? 0) * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L("已用 ") + durationText(est.totalElapsed) + (compact ? "" : L("（本步 ") + durationText(est.stepElapsed) + L("）")))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(compact ? .caption : .callout)
                    if !compact {
                        if !m.purpose.isEmpty { Text(L(m.purpose)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let r = est.remaining {
                            Text(L("预计还需 ") + durationText(r) + L("，约 ") + Date(timeIntervalSince1970: tl.date.timeIntervalSince1970 + r).formatted(date: .omitted, time: .shortened)
                                 + L(" 完成") + L("（按本机最近 \(est.historySamples) 次记录）")).font(.caption.weight(.medium)).monospacedDigit()
                        } else if let r = est.stepRemainingByRate {
                            Text(L("本步还需约 ") + durationText(r) + L("（按本步当前速度）")).font(.caption.weight(.medium)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
