import ArgumentParser
import MacBayKit

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Safely restore and re-externalize an app around its vendor update.",
        subcommands: [UpdateBeginCommand.self, UpdateFinishCommand.self, UpdateRunCommand.self, UpdateStatusCommand.self, UpdateScheduleCommand.self]
    )
}

struct UpdateBeginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "begin",
        abstract: "Restore a MacBay-managed app to /Applications before updating it."
    )

    @Argument(help: "Name or path of the MacBay-managed application.")
    var app: String

    @OptionGroup var options: UpdateWorkflowOptions

    func run() throws {
        let service = MacBayService()
        let formatter = CommandSupport.formatter(json: options.json)

        if options.dryRun {
            let progress = TerminalProgress(json: options.json)
            defer { progress.stop() }
            let report = try service.beginAppUpdate(
                appName: app,
                dryRun: true,
                progress: progress.update
            )
            progress.stop()
            try CommandSupport.printValue(report, json: options.json) { $0.updateWorkflow(report) }
            return
        }

        let previewProgress = TerminalProgress(json: options.json)
        let preview: UpdateWorkflowReport
        do {
            preview = try service.beginAppUpdate(
                appName: app,
                dryRun: true,
                progress: previewProgress.update
            )
            previewProgress.stop()
        } catch {
            previewProgress.stop()
            throw error
        }
        if !options.json {
            print(formatter.updateWorkflow(preview))
        }
        try CommandSupport.confirm(
            "MacBay will restore \(app) to /Applications so its vendor updater can replace it.",
            yes: options.yes,
            dryRun: false
        )

        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let result = try service.beginAppUpdate(
            appName: app,
            dryRun: false,
            progress: progress.update
        )
        progress.stop()
        try CommandSupport.printValue(result, json: options.json) { $0.updateWorkflow(result) }
    }
}

struct UpdateFinishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finish",
        abstract: "Re-externalize an updated app to its original MacBay volume."
    )

    @Argument(help: "Name or path of the app with an update in progress.")
    var app: String

    @Flag(name: .long, help: "Proceed if the app has a popup relocation risk.")
    var force = false

    @OptionGroup var options: UpdateWorkflowOptions

    func run() throws {
        let service = MacBayService()
        let formatter = CommandSupport.formatter(json: options.json)

        if options.dryRun {
            let progress = TerminalProgress(json: options.json)
            defer { progress.stop() }
            let report = try service.finishAppUpdate(
                appName: app,
                force: force,
                dryRun: true,
                progress: progress.update
            )
            progress.stop()
            try CommandSupport.printValue(report, json: options.json) { $0.updateWorkflow(report) }
            return
        }

        let previewProgress = TerminalProgress(json: options.json)
        let preview: UpdateWorkflowReport
        do {
            preview = try service.finishAppUpdate(
                appName: app,
                force: force,
                dryRun: true,
                progress: previewProgress.update
            )
            previewProgress.stop()
        } catch {
            previewProgress.stop()
            throw error
        }
        if !options.json {
            print(formatter.updateWorkflow(preview))
        }
        try CommandSupport.confirm(
            "MacBay will re-externalize the updated app to its original volume.",
            yes: options.yes,
            dryRun: false
        )

        let progress = TerminalProgress(json: options.json)
        defer { progress.stop() }
        let result = try service.finishAppUpdate(
            appName: app,
            force: force,
            dryRun: false,
            progress: progress.update
        )
        progress.stop()
        try CommandSupport.printValue(result, json: options.json) { $0.updateWorkflow(result) }
    }
}

struct UpdateRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the managed Kiro update cycle."
    )

    @Argument(help: "Managed updater target; currently 'Kiro CLI.app'.")
    var app: String

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompts.")
    var yes = false

    @Flag(name: .long, help: "Preview the update without changing files.")
    var dryRun = false

    @Flag(name: .long, help: "Invocation from MacBay's LaunchAgent.")
    var scheduled = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        guard app == "Kiro CLI.app" || app == "Kiro CLI" else {
            throw ValidationError("Managed update currently supports only 'Kiro CLI.app'.")
        }
        let service = MacBayService()
        let schedule = UpdateScheduleManager()
        if scheduled {
            let state = try schedule.status()
            guard state.enabled else {
                throw MacBayError.unsupportedOperation("Scheduled Kiro updates are disabled.")
            }
            if try service.updateStatus().contains(where: { $0.appName == "Kiro CLI.app" }) {
                let prior = try schedule.status()
                try schedule.recordRun(
                    outcome: "awaiting_action",
                    message: "A previous Kiro update is unfinished; the app and workflow were preserved in /Applications."
                )
                if prior.lastOutcome != "awaiting_action" {
                    schedule.postFailureNotification("A Kiro update needs attention. Run 'mb update status'.")
                }
                print("Skipped: a Kiro update is already awaiting manual completion.")
                return
            }
        }

        if dryRun {
            let report = try service.runKiroUpdate(dryRun: true)
            try CommandSupport.printValue(report, json: json) { $0.updateWorkflow(report) }
            return
        }
        if !scheduled {
            try CommandSupport.confirm(
                "MacBay will update Kiro locally, verify it, then return it to its original volume.",
                yes: yes,
                dryRun: false
            )
        }

        do {
            let result = try service.runKiroUpdate(dryRun: false)
            if scheduled {
                try schedule.recordRun(outcome: "success", message: "Updated and returned Kiro CLI to its MacBay volume.")
            }
            try CommandSupport.printValue(result, json: json) { $0.updateWorkflow(result) }
        } catch {
            guard scheduled else { throw error }
            if Self.shouldSkip(error) {
                try schedule.recordRun(outcome: "skipped", message: error.localizedDescription)
                print("Skipped Kiro update: \(error.localizedDescription)")
                return
            }
            try schedule.recordRun(outcome: "failed", message: error.localizedDescription)
            schedule.postFailureNotification("Kiro update failed. It remains in /Applications; run 'mb update status'.")
            throw error
        }
    }

    private static func shouldSkip(_ error: Error) -> Bool {
        guard let bayError = error as? MacBayError else { return false }
        switch bayError {
        case .activeProcesses:
            return true
        case let .invalidVolume(details):
            return details.localizedCaseInsensitiveContains("not mounted") ||
                details.localizedCaseInsensitiveContains("not connected")
        case .externalVolumeRequired:
            return true
        default:
            return false
        }
    }
}

struct UpdateStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show apps waiting for an update to finish."
    )

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        let records = try MacBayService().updateStatus()
        try CommandSupport.printValue(records, json: json) { $0.updateWorkflowStatus(records) }
    }
}
