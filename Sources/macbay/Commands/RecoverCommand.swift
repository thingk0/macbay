import ArgumentParser
import MacBayKit

struct RecoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Install a verified local copy when a recorded MacBay app target is missing."
    )

    @Argument(help: "Name of the MacBay-managed application to recover.")
    var app: String

    @Option(name: .long, help: "Path to an existing, verified .app bundle to install locally.")
    var from: String

    @Option(name: .long, help: "Expected CFBundleIdentifier for the application.")
    var expectedBundleId: String

    @Option(name: .long, help: "Expected signing TeamIdentifier for the application.")
    var expectedTeamId: String

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompts.")
    var yes = false

    @Flag(name: .long, help: "Preview recovery without changing files.")
    var dryRun = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        let service = MacBayService()
        if dryRun {
            let report = try service.recoverLocalApp(
                appName: app,
                from: from,
                expectedBundleIdentifier: expectedBundleId,
                expectedTeamIdentifier: expectedTeamId,
                dryRun: true
            )
            try CommandSupport.printValue(report, json: json) { _ in
                """
                Recovery preview · \(report.appName)
                  Install: \(report.candidatePath) → \(report.sourcePath)
                  Missing MacBay target: \(report.externalPath)
                  Identity: \(report.bundleIdentifier) · Team \(report.teamIdentifier)
                  Version: \(report.version ?? "Unknown")
                  Size: \(OutputFormatter.humanBytes(report.sizeBytes))
                  \(report.messages.joined(separator: "\n  "))
                  Dry run: no files were changed
                """
            }
            return
        }

        let preview = try service.recoverLocalApp(
            appName: app,
            from: from,
            expectedBundleIdentifier: expectedBundleId,
            expectedTeamIdentifier: expectedTeamId,
            dryRun: true
        )
        if !json {
            print("""
            Recovery · \(preview.appName)
              Install: \(preview.candidatePath) → \(preview.sourcePath)
              Missing MacBay target: \(preview.externalPath)
              Identity: \(preview.bundleIdentifier) · Team \(preview.teamIdentifier)
              Version: \(preview.version ?? "Unknown")
              Size: \(OutputFormatter.humanBytes(preview.sizeBytes))
            """)
        }
        try CommandSupport.confirm(
            "MacBay will install the verified app locally and remove only its stale manifest record.",
            yes: yes,
            dryRun: false
        )
        let result = try service.recoverLocalApp(
            appName: app,
            from: from,
            expectedBundleIdentifier: expectedBundleId,
            expectedTeamIdentifier: expectedTeamId,
            dryRun: false
        )
        try CommandSupport.printValue(result, json: json) { _ in
            "Recovered \(result.appName) to \(result.sourcePath)."
        }
    }
}
