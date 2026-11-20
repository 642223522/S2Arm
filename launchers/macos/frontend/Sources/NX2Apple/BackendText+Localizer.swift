// S2Arm（不是上游文件）：作业层（pack/jobs）给的文字按界面语言显示。作业层只说中文原句（检查项名、阶段名、日志、报错），
// 翻译走适配层 BackendText（与旧启动器 L() 同一套对照表与共享体验文案），语言跟界面的 loc.lang：中文界面显示原句，其余显示英文。
import NXModel
import NXLauncher
import S2ArmAppleAdapter

import NXCore

extension Lang {
    /// 共享文案表（launchers/shared/experience.v1.json）与作业请求用的语言代码：简中是 zh-Hans，其余同 frontend/l10n 的文件名（en，以后 zh-Hant / ja …）。
    ///   取代各处「lang.sharedCode」二选一：加一门语言只加文案，不改调用方（11-14 i18n 打底）
    nonisolated var sharedCode: String { self == .zh ? "zh-Hans" : code }
}

extension Localizer {
    /// 这门语言用全角标点（「、」「（）」「；」）还是半角：看文案文件里的列表分隔符 s2arm.punct.list，不按语言名判断（11-14 加新语言）
    nonisolated var cjkPunctuation: Bool { t("s2arm.punct.list") == "、" }

    /// 报错页的「故障报修」指引（BackendText.reportHint，按界面语言）
    nonisolated var reportHint: String { BackendText.reportHint(language: lang.sharedCode) }
    /// 一句作业层文字在当前界面语言下的显示。
    nonisolated func backend(_ text: String) -> String {
        LauncherCopy.note(BackendText.translate(text, language: lang.sharedCode))
    }

    /// 作业页日志行：阶段行带「▸ 」前缀（S2ArmLauncherModel.ingest），前缀不进翻译。
    nonisolated func backendLine(_ line: String) -> String {
        let value = line.hasPrefix("▸ ") ? String(line.dropFirst(2)) : line
        let translated = BackendText.translate(value, language: lang.sharedCode)
        return line.hasPrefix("▸ ") ? "▸ " + translated : translated
    }
}
