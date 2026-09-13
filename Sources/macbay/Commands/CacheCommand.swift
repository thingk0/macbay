import ArgumentParser
import MacBayKit

struct CacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Route developer package caches (npm, pnpm, Yarn, bun, uv, pip, Gradle, CocoaPods, Go, Android, Homebrew, Hugging Face) to external storage.",
        aliases: ["c"]
    )

    @Flag(name: .long, help: "Enable external cache routing.")
    var enable = false

    @Flag(name: .long, help: "Remove MacBay-managed cache environment settings.")
    var reset = false

    @OptionGroup var options: MutatingOptions

    func validate() throws {
        guard enable != reset else {
            throw ValidationError("Specify exactly one of --enable or --reset.")
        }
    }

    func run() throws {
        let command = reset ? "cache --reset" : "cache --enable"
        do {
            try CommandSupport.confirm(
                reset
                    ? "MacBay will remove its managed cache settings from ~/.zshrc."
                    : "MacBay will route developer caches to external storage and update ~/.zshrc.",
                yes: options.yes,
                dryRun: options.dryRun
            )
            let report = try MacBayService().cache(
                volumePath: options.volume,
                dryRun: options.dryRun,
                reset: reset
            )
            try CommandSupport.printValue(report, json: options.json) { $0.cache(report) }
            CommandSupport.recordHistory(
                command: command, subject: "developer caches",
                outcome: report.exitCode == 0 ? .success : .partial,
                undo: reset ? nil : "mb cache --reset",
                dryRun: options.dryRun
            )
            if report.exitCode != 0 {
                throw ExitCode(report.exitCode)
            }
        } catch {
            CommandSupport.recordHistory(
                command: command, subject: "developer caches",
                outcome: .failure, detail: error.localizedDescription, dryRun: options.dryRun
            )
            throw error
        }
    }
}
