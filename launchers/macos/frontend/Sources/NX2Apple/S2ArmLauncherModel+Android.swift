// S2Arm（不是上游文件）：出安卓包 + 装到已连接的安卓手机（开关后，缺省关）。作业层 pack/jobs/android_export.py：
// androidDevices（开关开没开 + adb 列出的手机）、android（出包，请求带 installSerial 就接着装）；出包走同一个 export 编排。
import Foundation
import S2ArmAppleAdapter

extension S2ArmLauncherModel {
    /// 问一次作业层：安卓出包开没开（开关只在后端读）、连着哪些手机；选过的那台不在了就清掉选择
    func loadAndroidPhones() {
        Task { @MainActor [weak self] in await self?.refreshAndroidPhones() }
    }

    func refreshAndroidPhones() async {
        guard let result = try? await provider.androidDevices() else { return }
        let on = result["enabled"] as? Bool == true
        ExportPlatform.androidEnabled = on
        androidEnabled = on
        let rows = result["devices"] as? [[String: Any]] ?? []
        androidPhones = rows
        if let pick = androidPhoneChoice, !rows.contains(where: { ($0["serial"] as? String) == pick }) { androidPhoneChoice = nil }
    }

    /// 出好装到哪台：玩家选的 > 只连着一台可用的就是它 > nil（只出 APK，不装）。"" = 玩家选了「不装」
    var androidPhone: String? {
        if let pick = androidPhoneChoice { return pick.isEmpty ? nil : pick }
        let ready = androidPhones.filter { ($0["state"] as? String) == "device" }
        return ready.count == 1 ? ready[0]["serial"] as? String : nil
    }
}
