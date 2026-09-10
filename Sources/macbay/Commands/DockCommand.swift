import ArgumentParser
import MacBayKit

struct DockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock",
        abstract: "Move an application to external storage and symlink it back."
    )

    @Argument(help: "Application name, such as Aside.app, or an application path.")
    var app: String

    @Flag(name: .long, help: "Force migration for apps flagged with popup risk.")
    var force = false

    @OptionGroup var options: MutatingOptions

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will move \(app) to external storage and replace it with a symlink.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let result = try MacBayService().dock(
            appName: app,
            volumePath: options.volume,
            dryRun: options.dryRun,
            force: force
        )
        try CommandSupport.printValue(result, json: options.json) { $0.migration(result) }
    }
}
