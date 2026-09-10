import ArgumentParser
import MacBayKit

struct XcodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Externalize Xcode DeviceSupport and remove unavailable simulators."
    )

    @OptionGroup var options: MutatingOptions

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will externalize Xcode DeviceSupport and delete unavailable simulators.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let report = try MacBayService().xcode(volumePath: options.volume, dryRun: options.dryRun)
        try CommandSupport.printValue(report, json: options.json) { $0.xcode(report) }
    }
}
