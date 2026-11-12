import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

/// 出包页「存放位置」下拉框一项显示什么名字（S2ArmLauncherModel.locationName，批量出包页、存储总览行首同）：具体路径（家目录缩写成 ~），
/// 不是卷名——同一块盘上的几个位置卷名一样（内置盘一律「系统盘」），只给卷名分不清是哪个文件夹。期望手写
final class StorageLocationNameTests: XCTestCase {
    func testShowsTheConcretePathNotTheVolumeName() {
        // 内置盘上的两个位置：都算「系统盘」卷，名字要分得清（卷名一样，只给卷名就分不清是哪个文件夹）
        XCTAssertEqual(S2ArmLauncherModel.locationName(path: NSHomeDirectory() + "/S2Arm", volume: "系统盘"), "~/S2Arm")
        XCTAssertEqual(S2ArmLauncherModel.locationName(path: NSHomeDirectory() + "/游戏库2", volume: "系统盘"), "~/游戏库2")
        // 外接盘：路径里自然带着盘名（Example 是公开仓扫描的合成用户名口径）
        XCTAssertEqual(S2ArmLauncherModel.locationName(path: "/Volumes/Example/S2Arm", volume: "移动硬盘"), "/Volumes/Example/S2Arm")
    }
}
