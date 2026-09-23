import Darwin
import Foundation

public struct UpdateScheduleStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let appName: String
    public let executablePath: String?
    public let hour: Int?
    public let minute: Int?
    public let lastRunAt: String?
    public let lastOutcome: String?
    public let lastMessage: String?
    public let launchAgentPath: String

    public init(
        enabled: Bool,
        appName: String = "Kiro CLI.app",
        executablePath: String? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        lastRunAt: String? = nil,
        lastOutcome: String? = nil,
        lastMessage: String? = nil,
        launchAgentPath: String
    ) {
        self.enabled = enabled
        self.appName = appName
        self.executablePath = executablePath
        self.hour = hour
        self.minute = minute
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.lastMessage = lastMessage
        self.launchAgentPath = launchAgentPath
    }
}

public struct UpdateScheduleManager {
    private struct State: Codable {
        var enabled: Bool
        var appName: String
        var executablePath: String
        var hour: Int
        var minute: Int
        var lastRunAt: String?
        var lastOutcome: String?
        var lastMessage: String?
    }

    public static let launchAgentLabel = "com.macbay.update.kiro-cli"

    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let homeDirectory: URL
    private let stateDirectory: URL
    private let launchAgentURL: URL
    private let stateURL: URL
    private let logURL: URL
    private let domain: String

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: uid_t = getuid()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.homeDirectory = homeDirectory
        self.stateDirectory = homeDirectory.appendingPathComponent(".local/state/macbay", isDirectory: true)
        self.launchAgentURL = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist")
        self.stateURL = homeDirectory.appendingPathComponent(".local/state/macbay/update-schedule.json")
        self.logURL = homeDirectory.appendingPathComponent(".local/state/macbay/update-schedule.log")
        self.domain = "gui/\(uid)"
    }

    public func status() throws -> UpdateScheduleStatus {
        let state = try loadState()
        let hasConfiguredAgent = state?.enabled == true && fileManager.fileExists(atPath: launchAgentURL.path)
        let isLoaded: Bool
        if hasConfiguredAgent {
            isLoaded = try commandRunner.run(
                "/bin/launchctl",
                arguments: ["print", "\(domain)/\(Self.launchAgentLabel)"]
            ).status == 0
        } else {
            isLoaded = false
        }
        return UpdateScheduleStatus(
            enabled: hasConfiguredAgent && isLoaded,
            executablePath: state?.executablePath,
            hour: state?.hour,
            minute: state?.minute,
            lastRunAt: state?.lastRunAt,
            lastOutcome: state?.lastOutcome,
            lastMessage: state?.lastMessage,
            launchAgentPath: launchAgentURL.path
        )
    }

    @discardableResult
    public func enable(executablePath: String, hour: Int = 4, minute: Int = 0) throws -> UpdateScheduleStatus {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw MacBayError.unsupportedOperation("Schedule time must be a valid local HH:MM time.")
        }
        let binary = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard executablePath.hasPrefix("/"),
              !binary.path.contains("/.build/"),
              !binary.path.hasPrefix("/private/tmp/"),
              fileManager.isExecutableFile(atPath: binary.path) else {
            throw MacBayError.unsupportedOperation(
                "Schedule requires an installed, executable mb path outside a build or temporary directory."
            )
        }

        let previousState = try loadState()
        let previousStateData = try? Data(contentsOf: stateURL)
        let previousAgentData = try? Data(contentsOf: launchAgentURL)
        if let previousAgentData {
            let current = try PropertyListSerialization.propertyList(
                from: previousAgentData,
                options: [],
                format: nil
            ) as? [String: Any]
            guard current?["Label"] as? String == Self.launchAgentLabel else {
                throw MacBayError.configFailed(
                    path: launchAgentURL.path,
                    details: "Refusing to replace a LaunchAgent not owned by MacBay."
                )
            }
        }

        let loaded = try commandRunner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(Self.launchAgentLabel)"])
        let wasLoaded = loaded.status == 0
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let arguments = [
            binary.path, "update", "run", "Kiro CLI.app", "--yes", "--scheduled", "--json"
        ]
        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "ProgramArguments": arguments,
            "WorkingDirectory": homeDirectory.path,
            "EnvironmentVariables": ["HOME": homeDirectory.path],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fileManager.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let state = State(
            enabled: true,
            appName: "Kiro CLI.app",
            executablePath: binary.path,
            hour: hour,
            minute: minute,
            lastRunAt: previousState?.lastRunAt,
            lastOutcome: previousState?.lastOutcome,
            lastMessage: previousState?.lastMessage
        )

        do {
            try data.write(to: launchAgentURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchAgentURL.path)
            try saveState(state)

            if wasLoaded {
                let bootout = try commandRunner.run("/bin/launchctl", arguments: ["bootout", domain, launchAgentURL.path])
                if bootout.status != 0 {
                    let stillLoaded = try commandRunner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(Self.launchAgentLabel)"])
                    if stillLoaded.status == 0 {
                        throw MacBayError.commandFailed(
                            executable: "/bin/launchctl",
                            status: bootout.status,
                            details: bootout.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
            }

            let bootstrap = try commandRunner.run("/bin/launchctl", arguments: ["bootstrap", domain, launchAgentURL.path])
            guard bootstrap.status == 0 else {
                throw MacBayError.commandFailed(
                    executable: "/bin/launchctl",
                    status: bootstrap.status,
                    details: bootstrap.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            restoreFile(launchAgentURL, data: previousAgentData)
            restoreFile(stateURL, data: previousStateData)
            if wasLoaded, previousAgentData != nil {
                let restored = try? commandRunner.run("/bin/launchctl", arguments: ["bootstrap", domain, launchAgentURL.path])
                if restored?.status != 0, var disabled = previousState {
                    disabled.enabled = false
                    try? saveState(disabled)
                }
            }
            throw error
        }
        return try status()
    }

    @discardableResult
    public func disable() throws -> UpdateScheduleStatus {
        let state = try loadState()
        let hasAgent = fileManager.fileExists(atPath: launchAgentURL.path)
        guard !hasAgent || isMacBayLaunchAgent(at: launchAgentURL) else {
            throw MacBayError.configFailed(
                path: launchAgentURL.path,
                details: "Refusing to disable a LaunchAgent not owned by MacBay."
            )
        }
        if hasAgent {
            let result = try commandRunner.run("/bin/launchctl", arguments: ["bootout", domain, launchAgentURL.path])
            if result.status != 0 {
                let loaded = try commandRunner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(Self.launchAgentLabel)"])
                if loaded.status == 0 {
                    throw MacBayError.commandFailed(
                        executable: "/bin/launchctl",
                        status: result.status,
                        details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
            try launchAgentURL.removeIfPresent(using: fileManager)
        }
        if var disabled = state {
            disabled.enabled = false
            try saveState(disabled)
        }
        return try status()
    }

    private func restoreFile(_ url: URL, data: Data?) {
        do {
            if let data {
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                try url.removeIfPresent(using: fileManager)
            }
        } catch {
            // The primary launchctl error is more actionable; keep the best-effort restoration visible via status.
        }
    }

    public func recordRun(outcome: String, message: String) throws {
        guard var state = try loadState() else { return }
        state.lastRunAt = macBayTimestamp()
        state.lastOutcome = outcome
        state.lastMessage = message
        try saveState(state)
    }

    public func updateDisabledStatus() throws -> Bool {
        guard fileManager.fileExists(atPath: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli") else {
            return false
        }
        let cli = "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
        let result = try commandRunner.run(cli, arguments: ["settings", "list", "--format", "json"])
        guard result.status == 0,
              let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return Self.containsDisabledSetting(object)
    }

    private static func containsDisabledSetting(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["app.disableAutoupdates"] as? Bool == true { return true }
            if let app = dictionary["app"] as? [String: Any],
               app["disableAutoupdates"] as? Bool == true { return true }
            return dictionary.values.contains(where: containsDisabledSetting)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsDisabledSetting)
        }
        return false
    }

    public func postFailureNotification(_ message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"MacBay\""
        _ = try? commandRunner.run("/usr/bin/osascript", arguments: ["-e", script])
    }

    private func isMacBayLaunchAgent(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        return plist["Label"] as? String == Self.launchAgentLabel
    }

    private func loadState() throws -> State? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        } catch {
            throw MacBayError.configFailed(path: stateURL.path, details: error.localizedDescription)
        }
    }

    private func saveState(_ state: State) throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

private extension URL {
    func removeIfPresent(using fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: path) else { return }
        try fileManager.removeItem(at: self)
    }
}
