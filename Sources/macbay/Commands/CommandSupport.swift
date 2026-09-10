import Foundation
import MacBayKit

enum CommandSupport {
    static func formatter(json: Bool) -> OutputFormatter {
        OutputFormatter(useColor: !json)
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
}
