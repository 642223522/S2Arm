import XCTest
@testable import S2ArmLauncher

// 发布标识：设置页与 AI 控制口 /help 显示的版本 / 构建号 / 包号都由 launchers/macos/build_app.py
// 写进 Info.plist（S2ABuildID），这里只钉住「怎么拼、缺字段时怎么退化」。
final class ReleaseTests: XCTestCase {
    func testDisplayJoinsVersionAndBuild() {
        XCTAssertEqual(S2ArmRelease.display("0.1.0", "769"), "0.1.0（769）")
    }
    func testDisplayWithoutBuildShowsVersionOnly() {
        XCTAssertEqual(S2ArmRelease.display("0.1.0", ""), "0.1.0")
    }
    func testInfoFieldsFallBackInsteadOfCrashing() {
        // 测试进程的 Bundle 没有打包时写入的 S2ABuildID，包号为空时界面不显示这一行（Views 里判空）
        XCTAssertFalse(S2ArmRelease.version.isEmpty)
        XCTAssertFalse(S2ArmRelease.label.isEmpty)
        XCTAssertTrue(S2ArmRelease.buildID.isEmpty || S2ArmRelease.buildID.contains("-"),
                      "包号形如 <短提交号>-<引擎指纹前 8>：\(S2ArmRelease.buildID)")
    }

    func testSettingsLabelUsesLocalizedDevWhenNoVersion() {
        // 源码里直接跑：Info.plist 没有版本号 → 设置页仍显示本地化的「开发版本」，不是英文 dev
        XCTAssertEqual(S2ArmRelease.settingsLabel(nil, ""), L("开发版本"))
        XCTAssertEqual(S2ArmRelease.settingsLabel("", "769"), L("开发版本"))
        // 有版本号时与既有 display 同形（有构建号带括号）
        XCTAssertEqual(S2ArmRelease.settingsLabel("0.1.0", "769"), "0.1.0（769）")
        XCTAssertEqual(S2ArmRelease.settingsLabel("0.1.0", ""), "0.1.0")
    }
}
