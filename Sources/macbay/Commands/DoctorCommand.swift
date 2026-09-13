import ArgumentParser
import MacBayKit

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose external links and volume records; --fix repairs unambiguous findings.",
        discussion: "Inspects application links under /Applications, known developer cache links, and the MacBay records on connected external volumes. With --fix, MacBay recreates links for recorded sources that went missing and repoints broken or circular links to their recorded copies; findings needing a judgment call are reported as skipped. Exit codes: 0 when nothing needs attention, 1 when problems or unverifiable items remain, 2 when the check itself failed.",
        aliases: ["doc"]
    )

    @OptionGroup var options: DoctorOptions

    func run() throws {
        let service = MacBayService()
        var report: DoctorReport
        do {
            report = try service.doctor(volumePath: options.volume)
            if options.fix {
                let fixable = report.autoFixableFindings.count
                if fixable > 0 {
                    try CommandSupport.confirm(
                        "MacBay will repair \(fixable) issue(s) found by doctor by relinking to their recorded copies.",
                        yes: options.yes,
                        dryRun: options.dryRun
                    )
                    report = try service.doctor(volumePath: options.volume, fix: true, dryRun: options.dryRun)
                }
            }
        } catch {
            CommandSupport.printFailure(error, json: options.json)
            throw ExitCode(2)
        }

        try CommandSupport.printValue(report, json: options.json) { $0.doctor(report) }

        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}
