import ArgumentParser
import MacBayKit

struct BackupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backups",
        abstract: "Inspect repair backups and remove selected unreferenced backups.",
        discussion: "Lists the repair backups stored under <Volume>/MacBay/Backups with their app, saved version, date, and logical size. The list is read-only. A backup referenced by an operation or recovery journal, or one whose metadata cannot be verified, is protected and cannot be removed. Removal is never automatic: pass --remove with the operation ID shown by the list, review the preview, then confirm. Exit codes: 0 when every requested backup was removed, 1 when a requested backup was protected, stale, missing, or failed to delete."
    )

    @OptionGroup var options: MutatingOptions

    @Option(
        name: .customLong("remove"),
        help: "Operation ID (full or unique prefix) of a backup to remove. Repeat to select several."
    )
    var remove: [String] = []

    func run() throws {
        guard !remove.isEmpty || (!options.yes && !options.dryRun) else {
            throw ValidationError("--yes and --dry-run only apply together with --remove.")
        }

        let service = MacBayService()

        guard !remove.isEmpty else {
            let inventory = try service.listRepairBackups(volumePath: options.volume)
            try CommandSupport.printValue(inventory, json: options.json) { $0.backups(inventory) }
            return
        }

        let plan = try service.planRepairBackupRemoval(ids: remove, volumePath: options.volume)
        if options.dryRun {
            try CommandSupport.printValue(plan, json: options.json) { $0.backupRemovalPlan(plan, dryRun: true) }
            if plan.exitCode != 0 {
                throw ExitCode(plan.exitCode)
            }
            return
        }

        guard !plan.selected.isEmpty else {
            try CommandSupport.printValue(plan, json: options.json) { $0.backupRemovalPlan(plan, dryRun: false) }
            if plan.exitCode != 0 {
                throw ExitCode(plan.exitCode)
            }
            return
        }

        if !options.json {
            print(CommandSupport.formatter(json: false).backupRemovalPlan(plan, dryRun: false))
        }
        try CommandSupport.confirm(
            "MacBay will permanently remove \(plan.selected.count) backup(s) (\(OutputFormatter.humanBytes(plan.totalBytes))).",
            yes: options.yes,
            dryRun: false
        )

        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let result = try service.executeRepairBackupRemoval(plan: plan, progress: progress.update)
        progress.stop()
        try CommandSupport.printValue(result, json: options.json) { $0.backupRemovalResult(result) }
        if result.exitCode != 0 {
            throw ExitCode(result.exitCode)
        }
    }
}
