import XCTest
@testable import S2ArmAppleAdapter

/// 找 Xcode 的目录（D-9WFW：玩家把 Xcode 装在扩展硬盘上）：先看 /Applications、~/Applications；兜底时外接卷的 Applications 与卷根都看，
///   /Volumes 里指回 / 的启动盘软链跳过。与作业层 pack/jobs/toolchain.py default_app_dirs / external_app_dirs 同一组目录
final class XcodeLocatorTests: XCTestCase {
    func testSearchDirsIncludeExternalVolumesAndSkipBootLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("s2arm-xcode-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let vols = root.appendingPathComponent("Volumes")
        try fm.createDirectory(at: vols.appendingPathComponent("Ext SSD/Applications"), withIntermediateDirectories: true)
        try fm.createDirectory(at: vols.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let boot = root.appendingPathComponent("boot")
        try fm.createDirectory(at: boot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: vols.appendingPathComponent("Macintosh HD"), withDestinationURL: boot)
        // 先找的目录不含外接卷（列外接卷会弹系统隐私窗，只在内置位置一份都没有时兜底）
        XCTAssertEqual(XcodeLocator.searchDirs(), ["/Applications", NSHomeDirectory() + "/Applications"])
        XCTAssertEqual(XcodeLocator.externalDirs(volumes: vols.path), [vols.path + "/Ext SSD/Applications", vols.path + "/Ext SSD",
                                                  vols.path + "/Other/Applications", vols.path + "/Other"])
    }
}
