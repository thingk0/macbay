import Foundation

public enum UpdateWorkflowPhase: String, Codable, Equatable, Sendable {
    case preparing
    case awaitingUpdate = "awaiting_update"
}

public struct UpdateWorkflowRecord: Codable, Equatable, Identifiable, Sendable {
    public let appName: String
    public let sourcePath: String
    public let externalPath: String
    public let bundleIdentifier: String
    public let originalVersion: String?
    public let originalBuild: String?
    public let volumePath: String
    public let volumeName: String
    public let volumeUUID: String
    public let startedAt: String
    public var phase: UpdateWorkflowPhase

    public var id: String { appName }

    public init(
        appName: String,
        sourcePath: String,
        externalPath: String,
        bundleIdentifier: String,
        originalVersion: String?,
        originalBuild: String?,
        volumePath: String,
        volumeName: String,
        volumeUUID: String,
        startedAt: String = macBayTimestamp(),
        phase: UpdateWorkflowPhase = .preparing
    ) {
        self.appName = appName
        self.sourcePath = sourcePath
        self.externalPath = externalPath
        self.bundleIdentifier = bundleIdentifier
        self.originalVersion = originalVersion
        self.originalBuild = originalBuild
        self.volumePath = volumePath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.startedAt = startedAt
        self.phase = phase
    }
}

public struct UpdateWorkflowReport: Codable, Equatable, Sendable {
    public let operation: String
    public let record: UpdateWorkflowRecord
    public let currentVersion: String?
    public let currentBuild: String?
    public let migration: MigrationResult?
    public let dryRun: Bool
    public let messages: [String]

    public init(
        operation: String,
        record: UpdateWorkflowRecord,
        currentVersion: String?,
        currentBuild: String?,
        migration: MigrationResult? = nil,
        dryRun: Bool,
        messages: [String] = []
    ) {
        self.operation = operation
        self.record = record
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.migration = migration
        self.dryRun = dryRun
        self.messages = messages
    }
}

public struct UpdateWorkflowStore {
    private struct State: Codable {
        let version: Int
        var records: [UpdateWorkflowRecord]
    }

    private static let currentVersion = 1
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

    public var stateURL: URL {
        stateDirectory.appendingPathComponent("updates.json")
    }

    private var lockURL: URL {
        stateDirectory.appendingPathComponent("updates.lock")
    }

    public func records() throws -> [UpdateWorkflowRecord] {
        guard fileManager.fileExists(atPath: stateURL.path) else { return [] }
        return try FileLock(url: lockURL).withLock {
            try loadUnlocked().records
        }
    }

    public func record(for appName: String) throws -> UpdateWorkflowRecord? {
        let key = Self.key(appName)
        return try records().first { Self.key($0.appName) == key || $0.sourcePath == appName }
    }

    public func insert(_ record: UpdateWorkflowRecord) throws {
        try modify { records in
            guard !records.contains(where: { Self.key($0.appName) == Self.key(record.appName) }) else {
                throw MacBayError.unsupportedOperation(
                    "An update workflow is already in progress for \(record.appName). Run 'mb update status' and resume with 'mb update finish'."
                )
            }
            records.append(record)
        }
    }

    public func update(_ record: UpdateWorkflowRecord) throws {
        try modify { records in
            guard let index = records.firstIndex(where: { Self.key($0.appName) == Self.key(record.appName) }) else {
                throw MacBayError.unsupportedOperation(
                    "No update workflow is recorded for \(record.appName). Run 'mb update begin' first."
                )
            }
            records[index] = record
        }
    }

    public func remove(appName: String) throws {
        try modify { records in
            records.removeAll { Self.key($0.appName) == Self.key(appName) || $0.sourcePath == appName }
        }
    }

    private func modify<T>(_ body: (inout [UpdateWorkflowRecord]) throws -> T) throws -> T {
        try FileLock(url: lockURL).withLock {
            var records = try loadUnlocked().records
            let result = try body(&records)
            try saveUnlocked(records)
            return result
        }
    }

    private func loadUnlocked() throws -> State {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return State(version: Self.currentVersion, records: [])
        }

        do {
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard state.version == Self.currentVersion else {
                throw MacBayError.configFailed(
                    path: stateURL.path,
                    details: "Unsupported update workflow state version \(state.version)."
                )
            }
            return state
        } catch let error as MacBayError {
            throw error
        } catch {
            throw MacBayError.configFailed(path: stateURL.path, details: error.localizedDescription)
        }
    }

    private func saveUnlocked(_ records: [UpdateWorkflowRecord]) throws {
        do {
            try fileManager.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(State(version: Self.currentVersion, records: records))
            try data.write(to: stateURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch let error as MacBayError {
            throw error
        } catch {
            throw MacBayError.configFailed(path: stateURL.path, details: error.localizedDescription)
        }
    }

    private static func key(_ appName: String) -> String {
        URL(fileURLWithPath: appName).lastPathComponent.lowercased()
    }
}
