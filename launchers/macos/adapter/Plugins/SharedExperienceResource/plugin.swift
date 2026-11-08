import Foundation
import PackagePlugin

/// 共享体验规格（launchers/shared/experience.v1.json）拷进适配层资源包：源码资源目录不存副本或软链（坑记录：软链进资源包后失效）。
@main struct SharedExperienceResource: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let source = context.package.directoryURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/experience.v1.json")
        let resource = context.pluginWorkDirectoryURL.appendingPathComponent("experience.v1.json")
        return [.buildCommand(displayName: "Copy shared experience specification",
                              executable: URL(fileURLWithPath: "/bin/cp"),
                              arguments: [source.path, resource.path],
                              inputFiles: [source], outputFiles: [resource])]
    }
}
