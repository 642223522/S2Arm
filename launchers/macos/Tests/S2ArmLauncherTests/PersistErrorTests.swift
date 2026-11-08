import XCTest
@testable import S2ArmLauncher

// 审计 P2-72：启动器数据写不进磁盘时在界面报一句（原先 try? 吞掉）。期望手算：私有目录改成只读 → 存设置失败、error 写明「设置没能写进磁盘」；
//   恢复可写 → 存设置成功、不报错，且文件里是新值
@MainActor final class PersistErrorTests: XCTestCase {
    func testPreferenceWriteFailureIsReportedAndSuccessIsSilent() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-persist-"+UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
            try? FileManager.default.removeItem(at:root)
        }
        let store=Store(privateRoot:root)
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:root.path)
        store.error=nil
        store.preferences.developerDir="/synthetic/a"; store.savePreferences()
        XCTAssertTrue(store.error?.contains("设置没能写进磁盘") == true, store.error ?? "没报错")
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
        store.error=nil
        store.preferences.developerDir="/synthetic/b"; store.savePreferences()
        XCTAssertNil(store.error)
        let saved=try JSONDecoder().decode(Preferences.self,from:Data(contentsOf:root.appendingPathComponent("preferences.json")))
        XCTAssertEqual(saved.developerDir, "/synthetic/b")
    }
}
