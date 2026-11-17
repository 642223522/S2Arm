// S2Arm（不是上游文件）：Apple TV（tvOS 版，11-15）。作业层 pack/jobs/tvos.py：tvDevices（配对过的电视）、tvInstall（装到 Apple TV）、
// tvSaveBackup（电视存档备份一轮）。从电视拉诊断走原来的「拉回诊断」（pullDiagnostics 作业已把 Apple TV 一起列进来）。
import Foundation
import S2ArmAppleAdapter

extension S2ArmLauncherModel {
    /// 存档自动备份间隔（同 TVPort Model.backupInterval：30 分钟）
    static let appleTVBackupInterval: UInt64 = 30 * 60

    /// 读配对过的 Apple TV（出包页「Apple TV」一行的下拉）；选过的那台不在了就清掉选择
    func loadAppleTVs() {
        Task { @MainActor [weak self] in
            guard let self, let rows = try? await self.provider.appleTVDevices() else { return }
            self.appleTVs = rows
            if let pick = self.appleTVChoice, !rows.contains(where: { ($0["id"] as? String) == pick }) { self.appleTVChoice = nil }
        }
    }

    /// 要装的那台：玩家选的 > 只有一台就是它 > nil（作业层按「只连着一台就用它，多台报 device_required」说）
    var appleTVDevice: String? { appleTVChoice ?? (appleTVs.count == 1 ? appleTVs[0]["id"] as? String : nil) }

    /// 装到 Apple TV（tvInstall 作业），进度 / 结局用通用作业页
    func installAppleTV(_ game: GameSummary) {
        guard !busy else { return }
        failAction(nil, game: nil)
        let device = appleTVDevice
        start(.installTV, game: game, name: game.name) { [weak self] sink in
            _ = try await self?.provider.installAppleTV(gameId: game.id, device: device, events: sink)
            self?.loadAppleTVs()
            return nil
        }
    }

    /// 启动器开着时每 30 分钟备份一轮电视上的存档（作业层自己判连没连电视；没连 / 有任务在跑就跳过这一轮）
    func appleTVBackupLoop() {
        guard !tvBackupStarted else { return }
        tvBackupStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.appleTVBackupInterval * 1_000_000_000)
                guard let self else { return }
                await self.appleTVBackupTick()
            }
        }
    }

    /// appleTVBackupLoop 的一轮（单测直接调）→ 作业结果；有任务在跑时不发起（nil）
    @discardableResult func appleTVBackupTick() async -> [String: Any]? {
        if busy { return nil }
        do { return try await provider.appleTVSaveBackup() }
        catch { NSLog("S2Arm：Apple TV 存档自动备份这一轮没成：%@", error.localizedDescription); return nil }
    }
}
