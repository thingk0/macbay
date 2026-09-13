import ArgumentParser
import MacBayKit

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a directory to external storage and symlink it back.",
        aliases: ["mv"]
    )

    @Argument(help: "Directory path to externalize, such as ~/Games or '~/Library/Application Support/Steam'.")
    var path: String

    @OptionGroup var options: MutatingOptions

    func run() throws {
        do {
            try CommandSupport.confirm(
                "MacBay will move \(path) to external storage and replace it with a symlink.",
                yes: options.yes,
                dryRun: options.dryRun
            )
            let progress = TerminalProgress(json: options.json)
            defer { progress.stop() }
            let result = try MacBayService().move(
                path: path,
                volumePath: options.volume,
                dryRun: options.dryRun,
                progress: progress.update
            )
            progress.stop()
            try CommandSupport.printValue(result, json: options.json) { $0.migration(result) }
            CommandSupport.recordHistory(
                command: "move", subject: result.sourcePath, outcome: .success,
                undo: "mb unmove \(ShellEnvironmentWriter.shellQuoted(result.sourcePath))", dryRun: options.dryRun
            )
        } catch {
            guard !CommandSupport.isCancellation(error) else { throw error }
            CommandSupport.recordHistory(
                command: "move", subject: MacBayPaths.expandedURL(path).path, outcome: .failure,
                detail: error.localizedDescription, dryRun: options.dryRun
            )
            throw error
        }
    }
}
