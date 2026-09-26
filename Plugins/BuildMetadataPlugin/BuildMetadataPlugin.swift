import Foundation
import PackagePlugin

@main
struct BuildMetadataPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        [.prebuildCommand(
            displayName: "Record MacDiff build commit and timestamp",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                context.package.directoryURL.appending(path: "scripts/generate-build-info.sh").path,
                context.package.directoryURL.path,
                context.pluginWorkDirectoryURL.path
            ],
            outputFilesDirectory: context.pluginWorkDirectoryURL
        )]
    }
}
