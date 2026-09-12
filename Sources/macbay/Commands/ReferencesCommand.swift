import ArgumentParser
import MacBayKit

struct ReferencesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "references",
        abstract: "Inspect stored app paths in specific files without changing files.",
        discussion: "Reads only the files passed with --path and reports stored application paths that no longer exist, with confirmed replacement candidates when one can be verified. Exit codes: 0 when every stored path checks out, 1 when missing paths, unreadable files, or incomplete reads were found, 2 when the arguments are invalid or the check itself failed.",
        aliases: ["refs"]
    )

    @Option(
        name: .customLong("path"),
        help: "Configuration file to inspect for stored app paths. Repeatable; directories are not accepted."
    )
    var path: [String] = []

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func validate() throws {
        guard !path.isEmpty else {
            throw ValidationError("Specify at least one file with --path <file>.")
        }
    }

    func run() throws {
        let report: ReferenceReport
        do {
            report = try MacBayService().references(paths: path)
        } catch {
            CommandSupport.printFailure(error, json: json)
            throw ExitCode(2)
        }

        try CommandSupport.printValue(report, json: json) { $0.references(report) }

        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}
