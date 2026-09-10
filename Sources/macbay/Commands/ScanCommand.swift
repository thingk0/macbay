import ArgumentParser
import MacBayKit

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discover large applications and developer caches."
    )

    @OptionGroup var options: ScanOptions

    func run() throws {
        let report = MacBayService().scan()
        try CommandSupport.printValue(report, json: options.json) { $0.scan(report) }
    }
}
