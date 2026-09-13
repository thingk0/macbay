import ArgumentParser
import MacBayKit

struct UndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Undo the most recent dock or move recorded in mb history.",
        discussion: "Looks at the newest successful entry in 'mb history'. A dock is reversed with 'mb undock' and a move with 'mb unmove', after a dry run confirms the current state still matches the entry. Any other operation, a partly successful one, or an entry that was already undone is refused with the reason. Failed attempts are skipped because they changed nothing. The undo itself is recorded in the history."
    )

    @OptionGroup var options: MutatingOptions

    func run() throws {
        let service = MacBayService()
        let plan = try service.planUndo()
        // Check the current state before asking anything.
        let preview = try service.undo(plan, volumePath: options.volume, dryRun: true)
        if options.dryRun {
            try CommandSupport.printValue(preview, json: options.json) { $0.undo(preview) }
            return
        }
        if !options.json {
            print(CommandSupport.formatter(json: false).undo(preview))
        }
        try CommandSupport.confirm(
            "MacBay will undo '\(plan.entry.command) \(plan.entry.subject)' by running \(plan.command).",
            yes: options.yes,
            dryRun: false
        )
        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let report = try service.undo(plan, volumePath: options.volume, dryRun: false, progress: progress.update)
        progress.stop()
        try CommandSupport.printValue(report, json: options.json) { $0.undo(report) }
    }
}
