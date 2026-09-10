import ArgumentParser
import MacBayKit

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discover large applications and developer caches.",
        discussion: "Discovers relocation candidates, already externalized applications (MacBay managed, unmanaged, or unconfirmed), and unresolved application symlinks."
    )

    @OptionGroup var options: ScanOptions

    func run() throws {
        let report = MacBayService().scan()
        try CommandSupport.printValue(report, json: options.json) { $0.scan(report) }
    }
}
