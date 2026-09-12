import ArgumentParser
import MacBayKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show storage health and docked items.",
        aliases: ["st"]
    )

    @OptionGroup var options: StatusOptions

    func run() throws {
        let report = try MacBayService().status(volumePath: options.volume)
        try CommandSupport.printValue(report, json: options.json) { $0.status(report) }
    }
}
