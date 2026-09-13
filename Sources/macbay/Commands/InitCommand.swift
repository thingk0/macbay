import ArgumentParser
import MacBayKit

import Darwin

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Choose and save the default external volume.",
        discussion: "Saves the external volume that commands use when --volume is not given. With no options the only eligible volume is selected automatically, and an interactive terminal offers a numbered list when several are available. Use --show to print the saved default and --reset to remove it.",
        aliases: ["i"]
    )

    @Option(name: [.customShort("v"), .long], help: "External volume mount path to save as the default.")
    var volume: String?

    @Flag(name: .long, help: "Print the saved default volume.")
    var show = false

    @Flag(name: .long, help: "Remove the saved default volume.")
    var reset = false

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompts.")
    var yes = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func validate() throws {
        let modes = [volume != nil, show, reset].filter { $0 }.count
        guard modes <= 1 else {
            throw ValidationError("Specify at most one of --volume, --show, or --reset.")
        }
    }

    func run() throws {
        let service = MacBayService()

        if show {
            let report = try service.showConfig()
            try CommandSupport.printValue(report, json: json) { $0.configReport(report) }
            return
        }

        if reset {
            do {
                let report = try service.resetConfig()
                try CommandSupport.printValue(report, json: json) { $0.configReport(report) }
                CommandSupport.recordHistory(
                    command: "init --reset", subject: "default volume",
                    outcome: .success, dryRun: false
                )
            } catch {
                CommandSupport.recordHistory(
                    command: "init --reset", subject: "default volume",
                    outcome: .failure, detail: error.localizedDescription, dryRun: false
                )
                throw error
            }
            return
        }

        let interactive = !json && isatty(STDIN_FILENO) != 0
        let chooser: (([StorageVolume]) throws -> Int)? = interactive ? { volumes in
            try CommandSupport.promptChoice(
                title: "Select the default external volume.",
                options: volumes.map { "\($0.name) (\($0.path))" }
            )
        } : nil

        do {
            let report = try service.initialize(
                volumePath: volume,
                chooser: chooser,
                confirmReplace: { previous, replacement in
                    try CommandSupport.confirm(
                        "MacBay will replace the saved default volume '\(previous.name)' (\(previous.path)) with '\(replacement.name)' (\(replacement.path)).",
                        yes: yes,
                        dryRun: false
                    )
                }
            )
            try CommandSupport.printValue(report, json: json) { $0.initReport(report) }
            CommandSupport.recordHistory(
                command: "init", subject: volume ?? "interactive",
                outcome: .success, dryRun: false
            )
        } catch {
            CommandSupport.recordHistory(
                command: "init", subject: volume ?? "interactive",
                outcome: .failure, detail: error.localizedDescription, dryRun: false
            )
            throw error
        }
    }
}
