import Foundation

public enum HistoryOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
    case partial
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public let timestamp: String
    /// CLI command name, e.g. "dock", "move", "cache --enable".
    public let command: String
    /// What the command acted on: an app name, a moved path, a volume.
    public let subject: String
    public let outcome: HistoryOutcome
    /// Extra context: failure reason, restored count, freed bytes.
    public let detail: String?
    /// The command that would reverse this operation, when one exists.
    public let undo: String?

    public init(
        timestamp: String = macBayTimestamp(),
        command: String,
        subject: String,
        outcome: HistoryOutcome,
        detail: String? = nil,
        undo: String? = nil
    ) {
        self.timestamp = timestamp
        self.command = command
        self.subject = subject
        self.outcome = outcome
        self.detail = detail
        self.undo = undo
    }
}

/// Appends one JSON line per mutating command to
/// ~/.local/state/macbay/history.jsonl (XDG_STATE_HOME aware) on the internal
/// disk, so history survives detached external volumes. Reference data only:
/// doctor verdicts and safety checks never read it. Recording failures are
/// swallowed — history must never break the operation it describes.
public struct HistoryStore {
    /// Rotate the log once it exceeds this size; one previous file is kept.
    public static let maxBytes: UInt64 = 5 * 1024 * 1024

    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public var stateDirectory: URL {
        if let xdgStateHome = environment["XDG_STATE_HOME"], xdgStateHome.hasPrefix("/") {
            return URL(fileURLWithPath: xdgStateHome, isDirectory: true)
                .appendingPathComponent("macbay")
        }
        return homeDirectory.appendingPathComponent(".local/state/macbay")
    }

    public var historyURL: URL {
        stateDirectory.appendingPathComponent("history.jsonl")
    }

    /// Rotated-away file kept for inspection; at most one generation old.
    public var rotatedURL: URL {
        stateDirectory.appendingPathComponent("history.1.jsonl")
    }

    /// Serializes concurrent writers so lines cannot interleave.
    private var lockURL: URL {
        stateDirectory.appendingPathComponent("history.lock")
    }

    /// Append an entry. Never throws: a broken history file or full disk must
    /// not fail the command being recorded.
    public func record(_ entry: HistoryEntry) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            _ = try FileLock(url: lockURL).withLock {
                try rotateIfNeeded()
                let line = try JSONEncoder().encode(entry) + Data("\n".utf8)
                if let handle = try? FileHandle(forWritingTo: historyURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: historyURL)
                }
                // History may contain sensitive paths; keep it owner-only.
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: historyURL.path
                )
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stateDirectory.path
            )
        } catch {
            // History is advisory; ignore write failures.
        }
    }

    /// Newest-first entries across the current and rotated files. Entries are
    /// appended in time order, so the last line of each file is its newest —
    /// per-file reversal orders correctly even when timestamps tie.
    public func entries(limit: Int? = nil, command: String? = nil) -> [HistoryEntry] {
        var loaded: [HistoryEntry] = []
        let decoder = JSONDecoder()
        for url in [historyURL, rotatedURL] where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            var fileEntries: [HistoryEntry] = []
            for rawLine in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(HistoryEntry.self, from: rawLine) {
                    fileEntries.append(entry)
                }
            }
            loaded.append(contentsOf: fileEntries.reversed())
        }
        if let command {
            loaded = loaded.filter { $0.command.hasPrefix(command) }
        }
        if let limit, limit >= 0 {
            loaded = Array(loaded.prefix(limit))
        }
        return loaded
    }

    private func rotateIfNeeded() throws {
        guard fileManager.fileExists(atPath: historyURL.path),
              let size = (try? fileManager.attributesOfItem(atPath: historyURL.path))?[.size] as? UInt64,
              size >= Self.maxBytes else { return }
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: historyURL, to: rotatedURL)
    }
}
