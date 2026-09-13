import ArgumentParser
import MacBayKit

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose external links and volume records; --fix repairs unambiguous findings.",
        discussion: "Inspects application links under /Applications, known developer cache links, and the MacBay records on connected external volumes. With --fix, MacBay repoints broken or circular links to their recorded copies when exactly one record claims the source; everything else — including recorded sources that went missing, which may have been removed intentionally — is reported as skipped. Exit codes: 0 when nothing needs attention, 1 when problems or unverifiable items remain, 2 when the check itself failed.",
        aliases: ["doc"]
    )

    @OptionGroup var options: DoctorOptions

    func run() throws {
        guard options.fix || (!options.yes && !options.dryRun) else {
            throw ValidationError("--yes and --dry-run only apply together with --fix.")
        }

        let service = MacBayService()
        let report: DoctorReport
        do {
            if !options.fix {
                report = try service.doctor(volumePath: options.volume)
            } else {
                // Dry-run first so the prompt lists exactly what would change.
                let preview = try service.doctor(volumePath: options.volume, fix: true, dryRun: true)
                let planned = preview.fixes.filter { $0.status == .planned }
                if options.dryRun || planned.isEmpty {
                    report = preview
                } else {
                    let lines = planned.map { "  - \($0.name): \($0.detail)" }.joined(separator: "\n")
                    try CommandSupport.confirm(
                        "MacBay will repair \(planned.count) finding(s):\n\(lines)",
                        yes: options.yes,
                        dryRun: false
                    )
                    report = try service.doctor(volumePath: options.volume, fix: true)
                    CommandSupport.recordHistory(
                        command: "doctor --fix",
                        subject: options.volume ?? "all volumes",
                        outcome: report.fixes.contains { $0.status == .failed } ? .partial : .success,
                        detail: "\(report.fixes.filter { $0.status == .fixed }.count) fixed",
                        dryRun: false
                    )
                }
            }
        } catch {
            if options.fix, !options.dryRun, !CommandSupport.isCancellation(error) {
                CommandSupport.recordHistory(
                    command: "doctor --fix",
                    subject: options.volume ?? "all volumes",
                    outcome: .failure, detail: error.localizedDescription, dryRun: false
                )
            }
            CommandSupport.printFailure(error, json: options.json)
            throw ExitCode(2)
        }

        try CommandSupport.printValue(report, json: options.json) { $0.doctor(report) }
        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}
