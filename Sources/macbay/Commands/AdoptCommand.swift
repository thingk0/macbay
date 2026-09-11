import ArgumentParser
import MacBayKit

struct AdoptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Adopt an externally located application into MacBay standard storage and manifest."
    )

    @Argument(help: "Application name, such as Example.app, or an application path.")
    var app: String

    @Flag(name: .long, help: "Force adoption for apps flagged with popup risk.")
    var force = false

    @OptionGroup var options: MutatingOptions

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will adopt \(app) into MacBay standard storage and register it in the manifest.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let result = try MacBayService().adopt(
            appName: app,
            volumePath: options.volume,
            dryRun: options.dryRun,
            force: force
        )
        try CommandSupport.printValue(result, json: options.json) { $0.migration(result) }
    }
}
