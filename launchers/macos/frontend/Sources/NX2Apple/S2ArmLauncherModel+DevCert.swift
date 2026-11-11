// S2Arm（不是上游文件）：开发者证书签名的 Mac 一侧（v0.2.4，作业层 pack/jobs/devcert.py）。
//   出包页「签名方式」选 Apple ID 或「我的开发者证书」；证书导入一次（.p12 + .mobileprovision + 密码），之后出包装机都用它签。
//   体检里的问题只提示、不挡出包和装机；密码只经环境变量交给导入那一次作业，不写进请求文件。
import Foundation
import S2ArmAppleAdapter

extension S2ArmLauncherModel {
    /// 重读证书现况（出包页出现、换了手机、导入 / 删除之后）；按选中的手机判在不在设备列表
    ///   失败不吞（剃刀 M12）：读失败保留原值并报原因——原先当成「没导入」，切到证书签名时又弹导入窗
    func refreshDevCert() {
        Task { await reloadDevCert() }
    }

    func reloadDevCert() async {
        do { devCert = try await provider.devCertStatus(device: selectedDevice?["udid"] as? String); readOK("s2arm.fail.devCert") }
        catch { reportFailure("s2arm.fail.devCert", error, passive: true) }
    }

    /// 导入：成功即切到证书签名，回 nil；失败回原因句（弹窗里显示）
    func importDevCert(p12: String, profile: String, password: String) async -> String? {
        do {
            _ = try await provider.devCertImport(p12: p12, profile: profile, password: password, device: selectedDevice?["udid"] as? String)
            await reloadDevCert()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 出包页切签名方式：选证书但还没导入 → 先开导入弹窗（导入成功才算切过去）
    func setDevCertActive(_ on: Bool) {
        if on && devCert?.imported != true { showDevCertImport = true; return }
        Task {
            do { try await provider.devCertUse(on) } catch { reportFailure("s2arm.fail.devCertUse", error) }
            await reloadDevCert()
        }
    }

    func deleteDevCert() {
        Task {
            do { try await provider.devCertDelete() } catch { reportFailure("s2arm.fail.devCertDelete", error) }
            await reloadDevCert()
        }
    }
}
