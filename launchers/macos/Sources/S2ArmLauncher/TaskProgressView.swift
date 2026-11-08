// UI adapted from LumaDock (MIT); see ../../README.md.
import SwiftUI

/// Counts are worker measurements. Unknown totals use an indeterminate linear bar.
struct TaskProgressView: View {
    let task: TaskRecord
    var compact = false
    var showsMilestoneBar = true
    private func amount(_ value: Double) -> String {
        if task.unit == "B" {
            return ByteCountFormatter.string(fromByteCount:Int64(min(Double(Int64.max-1024),max(0,value))),countStyle:.file)
        }
        return String(format:"%.0f",max(0,value))
    }
    var body: some View {
        if let plan=task.milestones, !plan.isEmpty, task.milestone != nil { MilestoneProgressView(task:task,compact:compact,showsBar:showsMilestoneBar) } else { legacy }
    }
    private var legacy: some View {
        VStack(alignment:.leading,spacing:6) {
            // 当前在做哪一步（10-23 本机走查：原来只写「处理中，总量暂不可确定」，看不出在干什么）
            if let stage=task.stage, !stage.isEmpty {
                HStack(spacing:6) {
                    Text(SharedExperience.stageLabel(stage)).font(.caption.weight(.medium))
                    if let index=task.stageIndex,let count=task.stageCount,count>1 {Text(L("第 \(index)/\(count) 步")).font(.caption).foregroundStyle(.secondary)}
                    Spacer()
                }
            }
            if !compact,let fraction=task.stageFraction,let index=task.stageIndex,let count=task.stageCount {
                // 上面已有「阶段名 · 第 x/y 步」时不再重复写「整体阶段 x/y」
                if (task.stage ?? "").isEmpty { ProgressView(L("整体阶段 \(index)/\(count)"),value:fraction).tint(.teal) } else { ProgressView(value:fraction).tint(.teal) }
            }
            if let fraction=task.progressFraction,let done=task.done,let total=task.total {
                ProgressView(value:fraction).progressViewStyle(.linear).tint(.teal)
                    .accessibilityLabel(L("当前阶段进度"))
                HStack {
                    Text("\(Int(fraction*100))%")
                    Text(amount(min(done,total))+" / "+amount(total))
                    if let unit=task.unit,let label=["files":"个文件","shaders":"个着色器","checks":"项检查"][unit] {Text(L(label))}
                    Spacer()
                    elapsed
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.teal)
                    .accessibilityLabel(L("处理中，总量暂不可确定"))
                HStack {
                    if let done=task.done,done>0 {Text(L("已处理：")+amount(done))}
                    else if (task.stage ?? "").isEmpty {Text(L("处理中，总量暂不可确定"))}
                    Spacer();elapsed
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var elapsed: some View {
        TimelineView(.periodic(from:.now,by:1)) {timeline in
            if let started=task.started {
                Text(L("已用 \(Int(min(315360000,max(0,timeline.date.timeIntervalSince1970-started)))) 秒"))
                    .monospacedDigit()
            }
        }
    }
}

struct ActiveTaskBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(L("正在处理 \(store.activeTasks.count) 个任务")).font(.caption.bold())
                Spacer()
                Button(L("查看全部任务")) {store.selection="tasks"}.controlSize(.small)
            }
            ForEach(Array(store.activeTasks.filter { $0.id != store.pageTask?.id }.prefix(2))) {task in
                VStack(alignment:.leading,spacing:4) {
                    // 有里程碑进度时下一行已写「第 x/y 步 阶段名」，标题行不再重复阶段名
                    let milestoneRow = !(task.milestones ?? []).isEmpty && task.milestone != nil
                    HStack {Text(task.title).font(.caption.bold());if !milestoneRow {Text(SharedExperience.stageLabel(task.stage ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)}}
                    TaskProgressView(task:task,compact:true)
                }
            }
        }.padding(WorkspaceLayout.cardInset).contentCard(WorkspaceLayout.cardRadius).padding(.horizontal,WorkspaceLayout.pageInset).padding(.bottom,12)
    }
}
