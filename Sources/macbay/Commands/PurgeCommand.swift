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
        let formatter = CommandSupport.formatter(json: json)
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

        let eligibleItems = previewItems.filter { !($0.isRunning && !includeRunning) }
        let skippedItems = previewItems.filter { $0.isRunning && !includeRunning }

        if eligibleItems.isEmpty {
            if json {
                let report = PurgeReport(
                    dryRun: dryRun,
                    purgedItems: [],
                    skippedItems: skippedItems,
                    totalReclaimedBytes: 0,
                    messages: ["All discovered caches belong to running applications. Use --include-running to purge them."]
                )
                try CommandSupport.printValue(report, json: true) { $0.purge(report) }
            } else {
                print(formatter.formatPurgeSkippedOnly(skippedItems: skippedItems))
            }
            return
        }

        let totalEligibleBytes = eligibleItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }

        // 1. Dry run: execute with dryRun: true on all preview items and print report
        if dryRun {
            let report = try service.purge(items: previewItems, options: purgeOptions, dryRun: true)
            try CommandSupport.printValue(report, json: json) { $0.purge(report) }
            return
        }

        // 2. JSON mode without --yes requires confirmation
        if json {
            guard yes else {
                let errPayload = MacBayErrorPayload(
                    code: "configuration_error",
                    message: "Confirmation required to execute purge for \(eligibleItems.count) cache target(s). Re-run with --yes in non-interactive mode.",
                    details: "Reclaimable storage: \(OutputFormatter.humanBytes(totalEligibleBytes))"
                )
                if let jsonStr = try? formatter.json(errPayload) {
                    fputs("\(jsonStr)\n", stderr)
                }
                throw ExitCode(1)
            }
            do {
                let report = try service.purge(items: previewItems, options: purgeOptions, dryRun: false)
                try CommandSupport.printValue(report, json: true) { $0.purge(report) }
                CommandSupport.recordHistory(
                    command: "purge", subject: "\(report.purgedItems.count) item(s)",
                    outcome: report.failedItems.isEmpty ? .success : .partial,
                    detail: "freed \(OutputFormatter.humanBytes(report.totalReclaimedBytes))"
                        + (report.failedItems.isEmpty ? "" : ", \(report.failedItems.count) failed"),
                    dryRun: dryRun
                )
            } catch {
                CommandSupport.recordHistory(
                    command: "purge", subject: "\(previewItems.count) item(s)",
                    outcome: .failure, detail: error.localizedDescription, dryRun: dryRun
                )
                throw error
            }
            return
        }

        // 3. Interactive / unattended execution
        let groups = PurgeAppGroup.group(items: eligibleItems)

        let itemsToPurge: [PurgeItem]
        if yes {
            itemsToPurge = eligibleItems
        } else {
            print(formatter.formatPurgeInteractivePreview(
                groups: groups,
                skippedItems: skippedItems,
                totalEligibleBytes: totalEligibleBytes
            ))
            print("")

            var chosenItems: [PurgeItem]?
            while true {
                print("Select target(s) to purge [1 for all, comma-separated (e.g. 2, 4), or 'q' to cancel]: ", terminator: "")
                guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
                    print("Cancelled.")
                    return
                }

                if let selectedIndices = PurgeAppGroup.parseSelection(input: input, groupCount: groups.count) {
                    let chosenGroups = selectedIndices.sorted().map { groups[$0] }
                    chosenItems = chosenGroups.flatMap(\.items)
                    let names = chosenGroups.map(\.appName).joined(separator: ", ")
                    print("")
                    print("Purging selected targets: \(names)...")
                    break
                } else {
                    let lower = input.lowercased()
                    if lower == "q" || lower == "quit" || lower == "n" || lower == "no" || lower == "cancel" {
                        print("Cancelled.")
                        return
                    }
                    print("Invalid selection. Please enter 1 for all, numbers 2-\(groups.count + 1), or 'q' to cancel.")
                }
            }

            guard let confirmedItems = chosenItems else {
                print("Cancelled.")
                return
            }
            itemsToPurge = confirmedItems
        }

        let report: PurgeReport
        do {
            report = try service.purge(items: itemsToPurge, options: purgeOptions, dryRun: false)
        } catch {
            CommandSupport.recordHistory(
                command: "purge", subject: "\(itemsToPurge.count) item(s)",
                outcome: .failure, detail: error.localizedDescription, dryRun: dryRun
            )
            throw error
        }
        print(formatter.purge(report))
        CommandSupport.recordHistory(
            command: "purge", subject: "\(report.purgedItems.count) item(s)",
            outcome: report.failedItems.isEmpty ? .success : .partial,
            detail: "freed \(OutputFormatter.humanBytes(report.totalReclaimedBytes))"
                + (report.failedItems.isEmpty ? "" : ", \(report.failedItems.count) failed"),
            dryRun: dryRun
        )
    }
}
