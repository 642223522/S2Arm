import Foundation
import PackagePlugin

/// 共享规格（launchers/shared/experience.v1.json 体验规格、game_settings.v1.json 游戏设置定义表、l10n/ 各语言叠加文案）拷进适配层资源包：
/// 源码资源目录不存副本或软链（坑记录：软链进资源包后失效）。
@main struct SharedExperienceResource: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let shared = context.package.directoryURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared")
        // 各语言叠加文案 launchers/shared/l10n/<语言>.json 拷成 l10n.<语言>.json（11-14 i18n：加一门语言只加文件，不改这里）
        let l10n = shared.appendingPathComponent("l10n")
        let languages = ((try? FileManager.default.contentsOfDirectory(atPath: l10n.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        let files = [("experience.v1.json", shared.appendingPathComponent("experience.v1.json")),
                     ("game_settings.v1.json", shared.appendingPathComponent("game_settings.v1.json"))]
            + languages.map { ("l10n." + $0, l10n.appendingPathComponent($0)) }
        return files.map { name, source in
            let resource = context.pluginWorkDirectoryURL.appendingPathComponent(name)
            return .buildCommand(displayName: "Copy shared specification \(name)", executable: URL(fileURLWithPath: "/bin/cp"),
                                 arguments: [source.path, resource.path], inputFiles: [source], outputFiles: [resource])
        }
    }
}
