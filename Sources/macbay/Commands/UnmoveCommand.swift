import ArgumentParser
import MacBayKit

struct UnmoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmove",
        abstract: "Restore a moved directory back to internal storage.",
        aliases: ["umv"]
    )

    @Argument(help: "Original directory path that is now a symlink.")
    var path: String

    @OptionGroup var options: MutatingOptions

    func run() throws {
        do {
            try CommandSupport.confirm(
                "MacBay will restore \(path) to internal storage and remove the symlink.",
                yes: options.yes,
                dryRun: options.dryRun
            )
            let progress = TerminalProgress(json: options.json)
            defer { progress.stop() }
            let result = try MacBayService().unmove(
                path: path,
                volumePath: options.volume,
                dryRun: options.dryRun,
                progress: progress.update
            )
            progress.stop()
            try CommandSupport.printValue(result, json: options.json) { $0.migration(result) }
            CommandSupport.recordHistory(
                command: "unmove", subject: path, outcome: .success,
                undo: "mb move \(path)", dryRun: options.dryRun
            )
        } catch {
            CommandSupport.recordHistory(
                command: "unmove", subject: path, outcome: .failure,
                detail: error.localizedDescription, dryRun: options.dryRun
            )
            throw error
        }
    }
}
