import Foundation
import ArgumentParser
import MacBayKit

struct PurgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Purge abandoned application caches and temporary files.",
        aliases: ["pu"]
    )

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation prompts.")
    var yes: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Preview actions without modifying files.")
    var dryRun: Bool = false

    @Flag(name: .customLong("json"), help: "Output machine-readable JSON.")
    var json: Bool = false

    @Option(name: .customLong("app"), help: "Purge caches for specific app name(s) only (case-insensitive).")
    var appFilter: [String] = []

    @Flag(name: .customLong("include-running"), help: "Purge caches even if the application is currently running.")
    var includeRunning: Bool = false

    @Flag(name: .customLong("include-logs"), help: "Include old diagnostic crash logs in ~/Library/Logs.")
    var includeLogs: Bool = false

    @Flag(name: .customLong("no-homebrew"), help: "Exclude Homebrew download caches.")
    var noHomebrew: Bool = false

    func run() throws {
        let service = MacBayService()
        let purgeOptions = PurgeOptions(
            appFilter: appFilter,
            includeRunning: includeRunning,
            includeLogs: includeLogs,
            includeHomebrew: !noHomebrew
        )

        let previewItems = service.scanPurge(options: purgeOptions)
        if previewItems.isEmpty {
            if json {
                let emptyReport = PurgeReport(dryRun: dryRun, purgedItems: [], totalReclaimedBytes: 0)
                try CommandSupport.printValue(emptyReport, json: true) { $0.purge(emptyReport) }
            } else {
                print("No purgeable caches found.")
            }
            return
        }

        let totalEligibleBytes = previewItems
            .filter { !($0.isRunning && !includeRunning) }
            .reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let formattedSize = OutputFormatter.humanBytes(totalEligibleBytes)

        try CommandSupport.confirm(
            "MacBay will purge \(previewItems.count) application cache target(s), reclaiming approximately \(formattedSize).",
            yes: yes,
            dryRun: dryRun
        )

        let report = try service.purge(options: purgeOptions, dryRun: dryRun)
        try CommandSupport.printValue(report, json: json) { $0.purge(report) }
    }
}
