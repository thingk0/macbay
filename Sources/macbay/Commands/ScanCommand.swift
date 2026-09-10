import Foundation
import ArgumentParser
import MacBayKit

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discover large applications and developer caches.",
        discussion: "Discovers relocation candidates, already externalized applications (MacBay managed, unmanaged, or unconfirmed), and unresolved application symlinks."
    )

    /// Overrides the directories that are scanned for applications.
    ///
    /// Hidden because /Applications is the only meaningful target for users. Tests
    /// point this at a fixture so they do not walk the machine's real application
    /// directory, which is slow on a host with large bundles such as Xcode.
    @Option(name: .customLong("applications-dir"), help: .hidden)
    var applicationsDirectories: [String] = []

    @OptionGroup var options: ScanOptions

    func run() throws {
        let report = applicationsDirectories.isEmpty
            ? MacBayService().scan()
            : MacBayService().scan(
                applicationDirectories: applicationsDirectories.map { URL(fileURLWithPath: $0) }
            )
        try CommandSupport.printValue(report, json: options.json) { formatter in
            formatter.scan(report, verbose: options.verbose)
        }
    }
}
