import SwiftUI

// G03: consume the worker's byte budget; never infer unmeasured cache costs.
struct SpaceBudget: Codable, Equatable {
    var gameBytes: Int64?
    var volumes: [SpaceVolume]
    var unknown: [SpaceUnknown]?
    // 玩家点过「仍然继续」（请求带 spaceOverride）：预检没过也照跑了，失败页不再给这个按钮
    var override: Bool?
}

struct SpaceUnknown: Codable, Equatable {
    var id: String
    var role: String?
    var label: String
    var note: String?
}

struct SpaceVolume: Codable, Equatable {
    var role: String
    var volume: String
    var needBytes: Int64?
    var freeBytes: Int64?
    var enough: Bool?
    var basis: String?
    var note: String?
    var unknown: [String]?

    enum Status { case sufficient, insufficient, unknown }
    var status: Status {
        if enough == false { return .insufficient }
        guard let needBytes, let freeBytes, needBytes >= 0, freeBytes >= 0 else { return .unknown }
        if freeBytes < needBytes { return .insufficient }
        return enough == true ? .sufficient : .unknown
    }
    var roleName: String {
        L(["library":"游戏库与产物", "staging":"临时复制"][role] ?? "数据卷")
    }
    var basisName: String {
        L(["rule":"经验预算", "exact":"按实际复制量计算", "measured":"按实测"][basis ?? ""] ?? "预算依据未知")
    }
    var statusName: String {
        switch status {
        case .sufficient: return L("达到预检门槛")
        case .insufficient: return L("空间不足")
        case .unknown: return L("空间状态未知")
        }
    }
    var statusSymbol: String {
        switch status {
        case .sufficient: return "checkmark.circle"
        case .insufficient: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

func budgetBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes >= 0 else { return L("未测") }
    return ByteCountFormatter.string(fromByteCount:bytes, countStyle:.file)
}

/// Evidence remains available on failed/completed tasks and after catalogue reload.
/// System disclosure controls inherit Liquid Glass; content keeps an opaque reading surface.
struct TaskBudgetView: View {
    let task: TaskRecord
    var body: some View {
        VStack(alignment:.leading, spacing:12) {
            if let space = task.space {
                if !space.volumes.isEmpty, space.volumes.allSatisfy({ $0.status == .sufficient }) {
                    // 预检通过：只写一行真读数（各盘预检时的可用空间）；门槛是经验规则，不当读数摆出来（10-25 维护者）
                    Label(L("空间预检通过") + " · " + space.volumes.map { L($0.volume) + " " + L("可用 ") + budgetBytes($0.freeBytes) }.joined(separator:"，"),
                          systemImage:"internaldrive").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    VStack(alignment:.leading, spacing:10) {
                        Label(L("空间预检"), systemImage:"internaldrive").font(.callout.bold())
                        LabeledContent(L("源文件大小"), value:budgetBytes(space.gameBytes))
                            .font(.callout).monospacedDigit()
                        ForEach(Array(space.volumes.enumerated()), id:\.offset) { _, volume in
                            volumeRow(volume)
                        }
                        if space.volumes.isEmpty {
                            Label(L("空间状态未知"), systemImage:"questionmark.circle").foregroundStyle(.secondary)
                        }
                        ForEach(Array((space.unknown ?? []).enumerated()), id:\.offset) { _, item in
                            VStack(alignment:.leading, spacing:3) {
                                Text(L(item.label) + " · " + L("未量化，不计入门槛")).font(.caption.weight(.medium))
                                if let note = item.note, !note.isEmpty { Text(L(note)).font(.caption) }
                            }.foregroundStyle(.secondary)
                        }
                        Text(L("这是预检时的空间快照，重试时会重新检查；达到门槛不代表后续不会用满磁盘。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            }
        }
    }

    private func volumeRow(_ volume: SpaceVolume) -> some View {
        VStack(alignment:.leading, spacing:6) {
            Text(volume.roleName + " · " + L(volume.volume)).font(.callout.weight(.medium))
            Label(volume.statusName, systemImage:volume.statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(volume.status == .insufficient ? Color.red : Color.secondary)
            ViewThatFits(in:.horizontal) {
                HStack(spacing:16) { amounts(volume) }
                VStack(alignment:.leading, spacing:4) { amounts(volume) }
            }.font(.callout).monospacedDigit()
            Text(volume.basisName).font(.caption.weight(.medium))
            if let note = volume.note, !note.isEmpty {
                Text(L(note)).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth:.infinity, alignment:.leading).contentCard(10)
    }

    @ViewBuilder private func amounts(_ volume: SpaceVolume) -> some View {
        Text(L("需要：") + budgetBytes(volume.needBytes))
        Text(L("可用：") + budgetBytes(volume.freeBytes))
    }
}
