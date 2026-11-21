import Foundation
import S2ArmShellBridge

/// 多款容器的「文档根」：游戏目录 <文档根>/games/<程序号>，tvOS 上资源包也在其下 <文档根>/games/<程序号>/资源包。
/// 相对位置直接读宿主 C 侧 runtime/include/s2a_docs.h 的 S2A_CONTAINER_DOCS_REL（经 S2ArmShellBridge 的 s2a_shell_docs.h）：iOS 为 Documents；
/// tvOS 不让 App 写 Documents，为 Library/Caches/S2Arm（系统空间紧时会被清，存档另有持久化，见 TVSaveStore.swift）。
public enum S2ArmContainer {
    public static let docsRel: String = S2A_CONTAINER_DOCS_REL
    /// <家>/<docsRel>
    public static func docsRoot(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(docsRel, isDirectory: true)
    }
    /// <文档根>/games
    public static func gamesRoot(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        docsRoot(home: home).appendingPathComponent("games", isDirectory: true)
    }
}
