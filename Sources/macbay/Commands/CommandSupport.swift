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
            throw MacBayError.unsupportedOperation("Cancelled")
        }
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
