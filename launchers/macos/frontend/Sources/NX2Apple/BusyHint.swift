// S2Arm（不是上游文件）：因为「有任务在跑」而置灰的按钮，悬停说明在等哪个任务、为什么要等（维护者 11-11：同一时间只跑一个任务是单壳方案的特点，
//   不改；但玩家看不出按钮为什么是灰的）。一条模板：「正在＜作业＞《游戏名》。所有游戏都装在同一个 S2Arm App 里……」，作业名取 s2arm.job.title.<种类>。
// 置灰的按钮自己收不到悬停，所以忙时在它上面盖一层透明的悬停区挂说明（只在忙时盖，不忙时什么都不加、不挡点击）。
import SwiftUI
import NXModel

extension S2ArmLauncherModel {
    /// 有任务在跑时的说明；不忙为 nil
    func busyHint(_ loc: Localizer) -> String? {
        guard busy, let s = session else { return nil }
        let key = "s2arm.job.title." + s.kind.rawValue
        let action = loc.t(key) == key ? loc.t("s2arm.job.running") : loc.t(key)
        let name = s.gameID == nil ? "" : loc.t("s2arm.busy.game").replacingOccurrences(of: "{0}", with: s.name)
        return loc.t("s2arm.busy.hint").replacingOccurrences(of: "{0}", with: action).replacingOccurrences(of: "{1}", with: name)
    }
}

private struct BusyHintModifier: ViewModifier {
    @ObservedObject var model: S2ArmLauncherModel
    let disabled: Bool
    @EnvironmentObject var loc: Localizer
    func body(content: Content) -> some View {
        content.overlay {
            if disabled, let hint = model.busyHint(loc) {   // 忙时仍能点的按钮（如出包排队）不盖，免得挡住点击
                Color.clear.contentShape(Rectangle()).help(hint)
                    .accessibilityElement().accessibilityLabel(hint).accessibilityIdentifier("busy.hint")
            }
        }
    }
}

extension View {
    /// 放在 .disabled(…) 之后：忙时悬停说明在等谁、为什么。disabled = 这个按钮此刻是否被禁用（缺省 = 只要忙就禁用的按钮）
    func busyHint(_ model: S2ArmLauncherModel, disabled: Bool = true) -> some View { modifier(BusyHintModifier(model: model, disabled: disabled)) }
}
