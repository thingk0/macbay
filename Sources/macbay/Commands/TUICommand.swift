import Foundation
import ArgumentParser
import MacBayKit
import MacBayTUI
import Darwin

struct TUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Launch the interactive terminal user interface."
    )

    func run() throws {
        guard MacBayTUI.isInteractiveTerminal() else {
            fputs("Error: Interactive terminal required for TUI mode (stdin/stdout must be a TTY and TERM must be supported).\n", stderr)
            throw ExitCode(1)
        }
        try MacBayTUI.run()
    }
}
