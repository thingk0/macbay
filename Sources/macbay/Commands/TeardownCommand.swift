import ArgumentParser
import MacBayKit

struct TeardownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Restore all externalized items and remove MacBay configuration.",
        aliases: ["td"]
    )

    @OptionGroup var options: MutatingOptions

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will restore every managed app and directory to internal storage, remove cache routing from ~/.zshrc, and forget the default volume.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let report = try MacBayService().teardown(
            volumePath: options.volume,
            dryRun: options.dryRun,
            progress: progress.update
        )
        progress.stop()
        try CommandSupport.printValue(report, json: options.json) { $0.teardown(report) }

        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}
