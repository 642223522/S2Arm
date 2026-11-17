// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPhone 版 S2Arm 的更新提示（11-16 维护者改为手动更新：「那改成更稳妥的手动更新吧 启动器和移动端都是」）：
//   - 新版启动器首次读到游戏库、有要更新的手机（phoneUpdates）→ 后台跑 installUpdatePrepare（不碰手机：按本引擎预先核好各款 iPhone 程序，点了以后装得快），
//     准备期间不出横幅；准备完出横幅「有新版，点这里更新」（ready = 准备好了 / onConnect = 没准备成，装机时照旧补），玩家点了才装（= 顶栏「更新 iPhone」）；
//   - 2 分钟循环（keptModulesLoop）只发现、重读游戏库，不自动装；玩家点了更新后横幅显示进度，装完 phoneUpdates 空了横幅自己收起。
import Foundation
import S2ArmAppleAdapter

enum PhoneBanner: Equatable { case preparing, ready, onConnect }

extension S2ArmLauncherModel {
    /// 启动后一次（refresh 的 startup）：有要更新的手机就后台准备，横幅跟着变
    /// 自动更新的后台作业失败不静默（0.5.0 候选验收）：每次失败写一行 <私有目录>/logs/phone-auto-update.log（诊断包收 logs/），带「连续第几次」；成功一次归零。同 Windows PhoneAutoUpdate.cs
    func notePhoneAuto(_ operation: String, _ failure: String?) {
        guard let failure else { phoneAutoFails[operation] = nil; return }
        let n = (phoneAutoFails[operation] ?? 0) + 1
        phoneAutoFails[operation] = n
        let dir = provider.client.environment.privateRoot.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("phone-auto-update.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = Data("\(stamp) \(operation) 失败（连续第 \(n) 次）：\(failure)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
        else { try? line.write(to: file) }
    }

    func preparePhoneUpdate() {
        guard !phoneUpdates.isEmpty, Self.autoUpdatePhoneOn(), !selfSignChosen, phoneBanner == nil, !phonePrepareStarted else { return }   // 选了导出自签：不准备、不出横幅
        phonePrepareStarted = true
        // 手动更新（11-16）：首启在电脑侧准备期间不出横幅（「正在更新 iPhone」那句只给玩家点了之后的装机），准备完直接出 ready / onConnect
        Task { [weak self] in
            guard let self else { return }
            var ok = false
            do { _ = try await self.provider.client.perform("installUpdatePrepare", automatic: true); ok = true; self.notePhoneAuto("installUpdatePrepare", nil) }
            catch { self.notePhoneAuto("installUpdatePrepare", String(describing: error)) }
            if self.phoneBanner == nil { self.phoneBanner = ok ? .ready : .onConnect }
        }
    }

    /// 横幅这一刻的文案键与百分比：正在更新 iPhone（手机槽 installUpdate）→ 进度；否则按准备结果；手机已是本版 → nil（不显示）
    var phoneBannerLine: (key: String, percent: Int?)? {
        guard let banner = phoneBanner else { return nil }
        if phoneBusy, let phone = phoneSession, phone.kind == .installUpdate {
            return ("phone.update.banner.progress", Int(((phone.progress.overall ?? 0) * 100).rounded()))
        }
        if phoneUpdates.isEmpty { return nil }
        switch banner {
        case .preparing: return ("phone.update.banner.preparing", nil)
        case .ready: return ("phone.update.banner.ready", nil)
        case .onConnect: return ("phone.update.banner.on_connect", nil)
        }
    }
}
