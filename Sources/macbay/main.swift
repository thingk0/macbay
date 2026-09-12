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
            XcodeCommand.self,
            CacheCommand.self,
            PurgeCommand.self,
            TUICommand.self
        ]
    )

    static func wantsJSONOutput(_ arguments: [String]) -> Bool {
        for argument in arguments.dropFirst() {
            if argument == "--" { return false }   // everything after the terminator is a value, not a flag
            if argument == "--json" { return true }
        }
        return false
    }

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
            } else if wantsJSONOutput(CommandLine.arguments) {
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
