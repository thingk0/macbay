import ArgumentParser
import Foundation
import MacBayKit

struct UpdateScheduleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Manage the optional Kiro CLI update schedule.",
        subcommands: [
            UpdateScheduleEnableCommand.self,
            UpdateScheduleStatusCommand.self,
            UpdateScheduleDisableCommand.self
        ]
    )
}

struct UpdateScheduleEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable the daily Kiro update schedule.")

    @Option(name: .long, help: "Local 24-hour time in HH:MM format (default: 04:00).")
    var time = "04:00"

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompts.")
    var yes = false

    @Flag(name: .long, help: "Preview without creating the LaunchAgent.")
    var dryRun = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        let schedule = UpdateScheduleManager()
        guard try schedule.updateDisabledStatus() else {
            throw MacBayError.unsupportedOperation(
                "Kiro background updates must be disabled first. Run 'mb update run Kiro CLI.app' once; it applies and verifies the setting."
            )
        }
        let pieces = time.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ValidationError("Use a valid local time such as 04:00.")
        }
        let argument = CommandLine.arguments.first ?? ""
        let executablePath = (argument.hasPrefix("/")
            ? URL(fileURLWithPath: argument)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument))
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: executablePath),
              !executablePath.contains("/.build/"),
              !executablePath.hasPrefix("/private/tmp/") else {
            throw MacBayError.unsupportedOperation(
                "Install MacBay at a stable executable path before enabling its schedule."
            )
        }

        if !json {
            print("Schedule preview · Kiro CLI")
            print("  Time: daily at \(String(format: "%02d:%02d", hour, minute)) local time")
            print("  Command: \(executablePath) update run Kiro CLI.app --scheduled")
            print("  LaunchAgent: \(try schedule.status().launchAgentPath)")
            print("  Default: disabled until this command runs")
        }
        if dryRun { return }
        try CommandSupport.confirm(
            "MacBay will install a LaunchAgent that checks for Kiro updates daily at \(String(format: "%02d:%02d", hour, minute)).",
            yes: yes,
            dryRun: false
        )
        let status = try schedule.enable(executablePath: executablePath, hour: hour, minute: minute)
        try CommandSupport.printValue(status, json: json) { _ in
            "Enabled: Kiro CLI update daily at \(String(format: "%02d:%02d", status.hour ?? 4, status.minute ?? 0))."
        }
    }
}

struct UpdateScheduleStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show Kiro update schedule state.")

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        let status = try UpdateScheduleManager().status()
        try CommandSupport.printValue(status, json: json) { _ in
            guard status.enabled else { return "Kiro update schedule · disabled" }
            let time = String(format: "%02d:%02d", status.hour ?? 4, status.minute ?? 0)
            var lines = ["Kiro update schedule · daily at \(time)", "  Executable: \(status.executablePath ?? "unknown")"]
            if let lastRunAt = status.lastRunAt {
                lines.append("  Last run: \(lastRunAt) · \(status.lastOutcome ?? "unknown")")
                if let message = status.lastMessage { lines.append("  Result: \(message)") }
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct UpdateScheduleDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable the Kiro update schedule.")

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompts.")
    var yes = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        try CommandSupport.confirm(
            "MacBay will unload and remove its Kiro update LaunchAgent.",
            yes: yes,
            dryRun: false
        )
        let status = try UpdateScheduleManager().disable()
        try CommandSupport.printValue(status, json: json) { _ in "Kiro update schedule disabled." }
    }
}
