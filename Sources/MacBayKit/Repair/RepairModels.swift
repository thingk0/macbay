import Foundation

public enum RepairAction: String, Codable, CaseIterable, Sendable {
    case redock = "redock"
    case keepLocal = "keep-local"
}

public struct AppCopyInfo: Codable, Equatable, Sendable {
    public let path: String
    public let bundleIdentifier: String?
    public let version: String?
    public let buildNumber: String?
    public let sizeBytes: UInt64
    public let signatureStatus: String
    public let signatureDetails: String?
    public let compatibilityGrade: String
    public let compatibilityReasons: [String]

    public init(
        path: String,
        bundleIdentifier: String?,
        version: String?,
        buildNumber: String?,
        sizeBytes: UInt64,
        signatureStatus: String,
        signatureDetails: String? = nil,
        compatibilityGrade: String,
        compatibilityReasons: [String] = []
    ) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildNumber = buildNumber
        self.sizeBytes = sizeBytes
        self.signatureStatus = signatureStatus
        self.signatureDetails = signatureDetails
        self.compatibilityGrade = compatibilityGrade
        self.compatibilityReasons = compatibilityReasons
    }
}

public struct RepairComparison: Codable, Equatable, Sendable {
    public let appName: String
    public let volumePath: String
    public let localCopy: AppCopyInfo
    public let externalCopy: AppCopyInfo
    public let canRedock: Bool
    public let redockBlockers: [String]
    public let suggestedActions: [RepairAction]

    public init(
        appName: String,
        volumePath: String,
        localCopy: AppCopyInfo,
        externalCopy: AppCopyInfo,
        canRedock: Bool,
        redockBlockers: [String] = [],
        suggestedActions: [RepairAction] = RepairAction.allCases
    ) {
        self.appName = appName
        self.volumePath = volumePath
        self.localCopy = localCopy
        self.externalCopy = externalCopy
        self.canRedock = canRedock
        self.redockBlockers = redockBlockers
        self.suggestedActions = suggestedActions
    }
}

public enum RepairPlanStatus: Codable, Equatable, Sendable {
    case ready
    case reviewRequired(reasons: [String], evidence: [String])
    case blocked(reason: String, solution: String)

    private enum CodingKeys: String, CodingKey {
        case type, reasons, evidence, reason, solution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready
        case "reviewRequired":
            let reasons = try container.decode([String].self, forKey: .reasons)
            let evidence = try container.decode([String].self, forKey: .evidence)
            self = .reviewRequired(reasons: reasons, evidence: evidence)
        case "blocked":
            let reason = try container.decode(String.self, forKey: .reason)
            let solution = try container.decode(String.self, forKey: .solution)
            self = .blocked(reason: reason, solution: solution)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown RepairPlanStatus type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try container.encode("ready", forKey: .type)
        case let .reviewRequired(reasons, evidence):
            try container.encode("reviewRequired", forKey: .type)
            try container.encode(reasons, forKey: .reasons)
            try container.encode(evidence, forKey: .evidence)
        case let .blocked(reason, solution):
            try container.encode("blocked", forKey: .type)
            try container.encode(reason, forKey: .reason)
            try container.encode(solution, forKey: .solution)
        }
    }
}

public struct RepairPlan: Codable, Equatable, Sendable {
    public let action: RepairAction
    public let appName: String
    public let localURL: URL
    public let externalURL: URL
    public let backupURL: URL?
    public let stagingURL: URL?
    public let volumeURL: URL
    public let status: RepairPlanStatus
    public let sizeBytes: UInt64
    public let requiredExternalSpaceBytes: UInt64
    public let estimatedFreedInternalBytes: UInt64
    public let warnings: [String]

    public init(
        action: RepairAction,
        appName: String,
        localURL: URL,
        externalURL: URL,
        backupURL: URL?,
        stagingURL: URL?,
        volumeURL: URL,
        status: RepairPlanStatus,
        sizeBytes: UInt64,
        requiredExternalSpaceBytes: UInt64,
        estimatedFreedInternalBytes: UInt64,
        warnings: [String] = []
    ) {
        self.action = action
        self.appName = appName
        self.localURL = localURL
        self.externalURL = externalURL
        self.backupURL = backupURL
        self.stagingURL = stagingURL
        self.volumeURL = volumeURL
        self.status = status
        self.sizeBytes = sizeBytes
        self.requiredExternalSpaceBytes = requiredExternalSpaceBytes
        self.estimatedFreedInternalBytes = estimatedFreedInternalBytes
        self.warnings = warnings
    }
}

public enum RepairPhase: String, Codable, Sendable {
    case started
    case staged
    case backedUpExternal = "backed_up_external"
    case placedNewExternal = "placed_new_external"
    case linked
    case manifestUpdated = "manifest_updated"
    case completed
}

public struct RepairJournalRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let appName: String
    public let localPath: String
    public let externalPath: String
    public let backupPath: String
    public let stagingPath: String
    public let localBackupPath: String
    public let volumePath: String
    public var phase: RepairPhase
    public let timestamp: String
    public let originalManifestItem: DockedItem

    public init(
        schemaVersion: Int = 1,
        id: String,
        appName: String,
        localPath: String,
        externalPath: String,
        backupPath: String,
        stagingPath: String,
        localBackupPath: String,
        volumePath: String,
        phase: RepairPhase,
        timestamp: String,
        originalManifestItem: DockedItem
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.appName = appName
        self.localPath = localPath
        self.externalPath = externalPath
        self.backupPath = backupPath
        self.stagingPath = stagingPath
        self.localBackupPath = localBackupPath
        self.volumePath = volumePath
        self.phase = phase
        self.timestamp = timestamp
        self.originalManifestItem = originalManifestItem
    }

    public func updatingPhase(_ newPhase: RepairPhase) -> RepairJournalRecord {
        RepairJournalRecord(
            schemaVersion: schemaVersion,
            id: id,
            appName: appName,
            localPath: localPath,
            externalPath: externalPath,
            backupPath: backupPath,
            stagingPath: stagingPath,
            localBackupPath: localBackupPath,
            volumePath: volumePath,
            phase: newPhase,
            timestamp: timestamp,
            originalManifestItem: originalManifestItem
        )
    }
}

public enum RepairOutcome: Codable, Equatable, Sendable {
    case completed
    case noChanges(reason: String)
    case failed(stage: String, error: String, rollback: RollbackStatus)

    private enum CodingKeys: String, CodingKey {
        case type, reason, stage, error, rollback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "completed":
            self = .completed
        case "noChanges":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .noChanges(reason: reason)
        case "failed":
            let stage = try container.decode(String.self, forKey: .stage)
            let error = try container.decode(String.self, forKey: .error)
            let rollback = try container.decode(RollbackStatus.self, forKey: .rollback)
            self = .failed(stage: stage, error: error, rollback: rollback)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown RepairOutcome type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed:
            try container.encode("completed", forKey: .type)
        case let .noChanges(reason):
            try container.encode("noChanges", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .failed(stage, error, rollback):
            try container.encode("failed", forKey: .type)
            try container.encode(stage, forKey: .stage)
            try container.encode(error, forKey: .error)
            try container.encode(rollback, forKey: .rollback)
        }
    }
}

public struct RepairExecutionResult: Codable, Equatable, Sendable {
    public let action: RepairAction
    public let appName: String
    public let outcome: RepairOutcome
    public let localPath: String
    public let externalPath: String
    public let backupPath: String?
    public let symlinkPath: String?
    public let freedBytes: UInt64

    public init(
        action: RepairAction,
        appName: String,
        outcome: RepairOutcome,
        localPath: String,
        externalPath: String,
        backupPath: String? = nil,
        symlinkPath: String? = nil,
        freedBytes: UInt64 = 0
    ) {
        self.action = action
        self.appName = appName
        self.outcome = outcome
        self.localPath = localPath
        self.externalPath = externalPath
        self.backupPath = backupPath
        self.symlinkPath = symlinkPath
        self.freedBytes = freedBytes
    }
}

public struct RepairExecutionError: Error, LocalizedError, Sendable {
    public let stage: String
    public let underlyingError: String
    public let rollback: RollbackStatus

    public init(stage: String, underlyingError: String, rollback: RollbackStatus) {
        self.stage = stage
        self.underlyingError = underlyingError
        self.rollback = rollback
    }

    public var errorDescription: String? {
        "Repair failed at stage '\(stage)': \(underlyingError). Rollback: \(rollback)"
    }
}
