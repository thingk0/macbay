import Foundation
import ArgumentParser
import MacBayKit
import Darwin

struct RepairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Compare duplicate local/external application copies and execute recovery (redock or keep-local)."
    )

    @Argument(help: "Name or path of the application bundle to repair (e.g. 'Kiro CLI.app').")
    var app: String

    @Option(name: .customLong("action"), help: "Repair action to execute: 'redock' (re-externalize) or 'keep-local' (keep local copy and unmanage). If omitted, displays a read-only comparison.")
    var action: String?

    @Flag(name: .customLong("rollback"), help: "Roll back an interrupted repair operation recorded in the volume journal.")
    var rollback: Bool = false

    @Flag(name: .customLong("force"), help: "Proceed with redock despite popup risk warning.")
    var force: Bool = false

    @OptionGroup
    var options: MutatingOptions

    func run() throws {
        let service = MacBayService()
        let formatter = CommandSupport.formatter(json: options.json)

        // 1. Rollback mode
        if rollback {
            let result = try service.rollbackRepair(appName: app, volumePath: options.volume)
            try CommandSupport.printValue(result, json: options.json) { _ in
                formatter.formatRepairExecutionResult(result)
            }
            return
        }

        // 2. Read-only comparison mode (when --action is not specified)
        guard let actionStr = action else {
            let comparison = try service.compareApp(appName: app, volumePath: options.volume)
            try CommandSupport.printValue(comparison, json: options.json) { _ in
                formatter.formatRepairComparison(comparison)
            }
            return
        }

        // Validate action
        guard let repairAction = RepairAction(rawValue: actionStr) else {
            throw ValidationError("Invalid action '\(actionStr)'. Supported actions: 'redock', 'keep-local'.")
        }

        let progress = TerminalProgress(json: options.json)

        // 3. Preflight Inspection and Planning
        let plan: RepairPlan
        do {
            plan = try service.planRepair(
                appName: app,
                action: repairAction,
                volumePath: options.volume,
                progress: { msg in progress.update(.validating) }
            )
            progress.stop()
        } catch {
            progress.stop()
            throw error
        }

        // 4. Status Evaluation
        switch plan.status {
        case let .blocked(reason, solution):
            if options.json {
                CommandSupport.printFailure(MacBayError.unsupportedOperation(reason), json: true)
                throw ExitCode(1)
            } else {
                print(formatter.formatBlocked(appName: plan.appName, reason: reason, solution: solution))
                throw ExitCode(1)
            }

        case let .reviewRequired(reasons, evidence):
            guard force else {
                if options.json {
                    CommandSupport.printFailure(
                        MacBayError.forceRequired(
                            path: plan.localURL.path,
                            assessment: CompatibilityAssessment(
                                grade: .popupRisk,
                                reasons: reasons,
                                evidence: evidence
                            )
                        ),
                        json: true
                    )
                    throw ExitCode(1)
                } else {
                    let cmd = "mb repair \"\(plan.appName)\" --action \(repairAction.rawValue) --force"
                    print(formatter.formatReviewRequired(appName: plan.appName, reasons: reasons, commandToProceed: cmd))
                    throw ExitCode(1)
                }
            }

        case .ready:
            break
        }

        // 5. Display Plan
        if !options.json {
            print(formatter.formatRepairPlan(plan: plan, force: force, dryRun: options.dryRun))
        }

        // 6. Dry run check
        if options.dryRun {
            if options.json {
                try CommandSupport.printValue(plan, json: true) { _ in "" }
            }
            return
        }

        // 7. Confirmation
        if options.json {
            guard options.yes else {
                let errPayload = MacBayErrorPayload(
                    code: "configuration_error",
                    message: "Confirmation required to execute repair for \(plan.appName). Re-run with --yes in non-interactive mode.",
                    details: "Action: \(repairAction.rawValue), Local: \(plan.localURL.path), External: \(plan.externalURL.path)"
                )
                if let jsonStr = try? formatter.json(errPayload) {
                    fputs("\(jsonStr)\n", stderr)
                }
                throw ExitCode(1)
            }
        } else {
            if !options.yes {
                print("\nProceed with repair (\(repairAction.rawValue))? [y/N] ", terminator: "")
                guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      answer == "y" || answer == "yes" else {
                    print("Cancelled. No files were changed.")
                    return
                }
            }
        }

        // 8. Execution
        let execProgress = TerminalProgress(json: options.json)
        let result: RepairExecutionResult
        do {
            result = try service.executeRepair(
                plan: plan,
                force: force,
                progress: { msg in execProgress.update(.copying) }
            )
            execProgress.stop()
        } catch {
            execProgress.stop()
            throw error
        }

        try CommandSupport.printValue(result, json: options.json) { _ in
            formatter.formatRepairExecutionResult(result)
        }
    }
}
