import ArgumentParser
import MacBayKit

struct TeardownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Restore all externalized items and remove MacBay configuration.",
        aliases: ["td"]
    )

    @OptionGroup var options: MutatingOptions

    func run() throws {
        let report: TeardownReport
        do {
            try CommandSupport.confirm(
                "MacBay will restore every managed app and directory to internal storage, remove cache routing from ~/.zshrc, and forget the default volume.",
                yes: options.yes,
                dryRun: options.dryRun
            )
            let progress = TerminalProgress(json: options.json)
            defer { progress.stop() }
            report = try MacBayService().teardown(
                volumePath: options.volume,
                dryRun: options.dryRun,
                progress: progress.update
            )
        } catch {
            guard !CommandSupport.isCancellation(error) else { throw error }
            CommandSupport.recordHistory(
                command: "teardown", subject: options.volume ?? "all volumes",
                outcome: .failure, detail: error.localizedDescription, dryRun: options.dryRun
            )
            throw error
        }
        try CommandSupport.printValue(report, json: options.json) { $0.teardown(report) }
        CommandSupport.recordHistory(
            command: "teardown", subject: options.volume ?? "all volumes",
            outcome: report.failures.isEmpty ? .success : .partial,
            detail: "\(report.restored.count) restored, \(report.failures.count) failed",
            dryRun: options.dryRun
        )
        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}
