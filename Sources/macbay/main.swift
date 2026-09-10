import Foundation
import ArgumentParser
import MacBayKit
import Darwin

struct MacBay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mb",
        abstract: "The developer-first storage externalizer for macOS.",
        version: "1.0.0",
        subcommands: [
            StatusCommand.self,
            ScanCommand.self,
            DockCommand.self,
            UndockCommand.self,
            XcodeCommand.self,
            CacheCommand.self
        ]
    )

    static func execute() {
        do {
            var command = try parseAsRoot()
            try command.run()
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
