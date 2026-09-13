import Foundation
import ArgumentParser
import MacBayKit
import MacBayTUI
import Darwin

struct MacBay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mb",
        abstract: "The developer-first storage externalizer for macOS.",
        version: MacBayVersion.current,
        subcommands: [
            InitCommand.self,
            StatusCommand.self,
            ScanCommand.self,
            DoctorCommand.self,
            ReferencesCommand.self,
            DockCommand.self,
            AdoptCommand.self,
            UndockCommand.self,
            RepairCommand.self,
            MoveCommand.self,
            UnmoveCommand.self,
            XcodeCommand.self,
            CacheCommand.self,
            PurgeCommand.self,
            TeardownCommand.self,
            TUICommand.self
        ]
    )

    static func execute() {
        if CommandLine.arguments.count <= 1 {
            print(helpMessage())
            Darwin.exit(0)
        }

        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let exitCode as ExitCode {
            Darwin.exit(exitCode.rawValue)
        } catch {
            let code = exitCode(for: error)
            if code.isSuccess {
                exit(withError: error)
            } else if CommandLine.arguments.contains("--json") {
                let payload = MacBayErrorPayload(error: error)
                if let jsonString = try? OutputFormatter(useColor: false).json(payload) {
                    fputs("\(jsonString)\n", stderr)
                }
                let rawCode = code.rawValue
                Darwin.exit(rawCode != 0 ? rawCode : 1)
            } else {
                exit(withError: error)
            }
        }
    }
}

MacBay.execute()
