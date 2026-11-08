// swift-tools-version: 6.0
import PackageDescription

// S2Arm Apple 适配层：NX2Apple 派生前端与 S2Arm 作业层（pack/jobs/main.py）之间的唯一接缝。只依赖 Foundation，不碰 SwiftUI / AppKit。
// 单测在 launchers/macos/Tests/S2ArmAppleAdapterTests（随 Mac 包 swift test 与 launchers/macos/test.sh 一起跑）。
// 资源：作业层文字的中英对照表 Localizable.json + 共享体验规格（SharedExperienceResource 插件从 launchers/shared 拷入），
//   新旧两个 Mac 前端都经 BackendText 读这一份（.app 里是 Resources/S2ArmAppleAdapter_S2ArmAppleAdapter.bundle）。
let package = Package(
    name: "S2ArmAppleAdapter",
    platforms: [.macOS(.v13)],
    products: [.library(name: "S2ArmAppleAdapter", targets: ["S2ArmAppleAdapter"])],
    targets: [
        .target(name: "S2ArmAppleAdapter", resources: [.process("Resources")],
                swiftSettings: [.swiftLanguageMode(.v5)],
                plugins: [.plugin(name: "SharedExperienceResource")]),
        .plugin(name: "SharedExperienceResource", capability: .buildTool())
    ]
)
