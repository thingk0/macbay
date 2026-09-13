import Foundation
import MacBayKit

import Darwin

enum CommandSupport {
    static func formatter(
        json: Bool,
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OutputFormatter {
        let color = !json && OutputFormatter.isColorSupported(isTTY: isTTY, environment: environment)
        return OutputFormatter(useColor: color)
    }

    static func confirm(
        _ message: String,
        yes: Bool,
        dryRun: Bool
    ) throws {
        guard !yes, !dryRun else { return }
        print("\(message) [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              answer == "y" || answer == "yes" else {
            throw MacBayError.cancelled
        }
    }

    static func promptChoice(title: String, options: [String]) throws -> Int {
        print(title)
        for (index, option) in options.enumerated() {
            print("  \(index + 1)) \(option)")
        }
        print("Select a volume [1-\(options.count)]: ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let selected = Int(answer),
              options.indices.contains(selected - 1) else {
            throw MacBayError.cancelled
        }
        return selected - 1
    }

    static func printValue<T: Encodable>(
        _ value: T,
        json: Bool,
        human: (OutputFormatter) -> String
    ) throws {
        let formatter = formatter(json: json)
        if json {
            print(try formatter.json(value))
        } else {
            print(human(formatter))
        }
    }

    /// True when the error is the user answering "n" at a confirmation prompt.
    /// A cancelled operation never ran, so it must not appear in history.
    static func isCancellation(_ error: Error) -> Bool {
        (error as? MacBayError)?.isCancellation == true
    }

    /// Records one history entry for a mutating command. Recording failures are
    /// swallowed inside HistoryStore — history is reference data only.
    static func recordHistory(
        command: String,
        subject: String,
        outcome: HistoryOutcome,
        detail: String? = nil,
        undo: String? = nil,
        dryRun: Bool
    ) {
        guard !dryRun else { return }
        HistoryStore().record(HistoryEntry(
            command: command,
            subject: subject,
            outcome: outcome,
            detail: detail,
            undo: undo
        ))
    }

    static func printFailure(_ error: Error, json: Bool) {
        if json {
            let payload = MacBayErrorPayload(error: error)
            if let jsonString = try? formatter(json: true).json(payload) {
                fputs("\(jsonString)\n", stderr)
            }
        } else {
            let message = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
            fputs("Error: \(message)\n", stderr)
        }
    }
}
