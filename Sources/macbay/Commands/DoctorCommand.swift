import ArgumentParser
import MacBayKit

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose external links and volume records without changing files.",
        discussion: "Inspects application links under /Applications, known developer cache links, and the MacBay records on connected external volumes. Exit codes: 0 when nothing needs attention, 1 when problems or unverifiable items were found, 2 when the check itself failed."
    )

    @OptionGroup var options: DoctorOptions

    func run() throws {
        let report: DoctorReport
        do {
            report = try MacBayService().doctor(volumePath: options.volume)
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
