import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 本地玩家（#623）Mac 一侧：顶栏选的玩家怎么进 launch 请求。期望手写（pack/jobs/build.py runtime_env 认的 player 字段；用户号由 Python hashlib 独立算出）
@MainActor final class LocalPlayersLaunchTests: XCTestCase {
    func testNoPlayersMeansNoPlayerFieldAndTheCurrentPlayerOtherwise() throws {
        let name = "s2a.test.mac.players." + UUID().uuidString
        let d = try XCTUnwrap(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
        XCTAssertNil(S2ArmLauncherModel.launchPlayer(d))   // 没建过玩家：旧行为
        XCTAssertNil(S2ArmLauncherModel.playerRequest(d))
        XCTAssertNil(S2ArmEngineProvider.launchArguments(Settings(values: ["switch2ProAutoConnect": "0"]))["player"])
        let store = S2ArmLauncherModel.playerStore(defaults: d)
        _ = try store.add("Hong")
        let hong = try XCTUnwrap(S2ArmLauncherModel.launchPlayer(d))
        XCTAssertEqual([hong.serviceUser, hong.name, hong.folder], ["d7a43a96495d0a594e615dd88587b6bf", "Hong", "SaveData-Hong"])
        let args = S2ArmEngineProvider.launchArguments(Settings(values: ["playerUser": hong.serviceUser, "playerName": hong.name, "playerFolder": hong.folder]))
        XCTAssertEqual(args["player"] as? [String: String], ["user": "d7a43a96495d0a594e615dd88587b6bf", "name": "Hong", "folder": "SaveData-Hong"])
        // 存档作业（导入社区存档）带的 player 字段与起局同形
        XCTAssertEqual(S2ArmLauncherModel.playerRequest(d), ["user": "d7a43a96495d0a594e615dd88587b6bf", "name": "Hong", "folder": "SaveData-Hong"])
        store.select("")
        XCTAssertEqual(S2ArmLauncherModel.launchPlayer(d).map { [$0.serviceUser, $0.folder] }, ["first", "SaveData"])
        XCTAssertEqual(S2ArmLauncherModel.playerRequest(d), ["user": "first", "name": "", "folder": "SaveData"])
    }
}
