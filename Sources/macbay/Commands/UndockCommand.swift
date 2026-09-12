import ArgumentParser
import MacBayKit

struct UndockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undock",
        abstract: "Restore an application to internal /Applications.",
        aliases: ["ud"]
    )

    @Argument(help: "Application name, such as Example.app, or an application path.")
    var app: String

    @OptionGroup var options: MutatingOptions

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will restore \(app) to internal storage and remove its external copy.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let result = try MacBayService().undock(
            appName: app,
            volumePath: options.volume,
            dryRun: options.dryRun,
            progress: progress.update
        )
        progress.stop()
        try CommandSupport.printValue(result, json: options.json) { $0.migration(result) }
    }
}
