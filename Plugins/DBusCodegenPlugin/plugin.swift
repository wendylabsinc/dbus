import PackagePlugin
import Foundation

@main
struct DBusCodegenPlugin: BuildToolPlugin {
  func createBuildCommands(
    context: PluginContext,
    target: Target
  ) async throws -> [Command] {
    guard let target = target as? SourceModuleTarget else { return [] }

    let tool = try context.tool(named: "dbus-codegen")
    let outputDir = context.pluginWorkDirectory

    return target.sourceFiles
      .filter { $0.path.lastComponent.hasSuffix(".dbus.xml") }
      .map { xmlFile -> Command in
        let outputName = xmlFile.path.lastComponent
          .replacingOccurrences(of: ".dbus.xml", with: ".dbus.swift")
        let outputFile = outputDir.appending(outputName)

        return .buildCommand(
          displayName: "DBus codegen: \(xmlFile.path.lastComponent)",
          executable: tool.path,
          arguments: [
            xmlFile.path.string,
            "--output-dir", outputDir.string,
          ],
          inputFiles: [xmlFile.path],
          outputFiles: [outputFile]
        )
      }
  }
}
