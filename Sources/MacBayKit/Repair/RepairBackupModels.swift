import Foundation

public enum RepairBackupState: String, Codable, Equatable, Sendable {
    case unreferenced
    case referenced
    case unverifiable
}

public struct RepairBackupEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let appName: String
    public let path: String
    public let version: String?
    public let buildNumber: String?
    public let savedAt: String?
    public let sizeBytes: UInt64?
    public let state: RepairBackupState
    public let referencedBy: String?
    public let reason: String?

    public init(
        id: String,
        appName: String,
        path: String,
        version: String? = nil,
        buildNumber: String? = nil,
        savedAt: String? = nil,
        sizeBytes: UInt64? = nil,
        state: RepairBackupState,
        referencedBy: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.path = path
        self.version = version
        self.buildNumber = buildNumber
        self.savedAt = savedAt
        self.sizeBytes = sizeBytes
        self.state = state
        self.referencedBy = referencedBy
        self.reason = reason
    }
}

public struct RepairBackupSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let totalSizeBytes: UInt64
    public let referencedCount: Int
    public let unverifiableCount: Int

    public init(
        count: Int,
        totalSizeBytes: UInt64,
        referencedCount: Int,
        unverifiableCount: Int
    ) {
        self.count = count
        self.totalSizeBytes = totalSizeBytes
        self.referencedCount = referencedCount
        self.unverifiableCount = unverifiableCount
    }
}

public struct RepairBackupInventory: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let volumeName: String
    public let volumePath: String
    public let backupsRoot: String
    public let backups: [RepairBackupEntry]
    public let summary: RepairBackupSummary
    public let notes: [String]
    public let warnings: [String]

    public init(
        generatedAt: String,
        volumeName: String,
        volumePath: String,
        backupsRoot: String,
        backups: [RepairBackupEntry],
        summary: RepairBackupSummary,
        notes: [String],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.backupsRoot = backupsRoot
        self.backups = backups
        self.summary = summary
        self.notes = notes
        self.warnings = warnings
    }
}

public struct RepairBackupRemovalRefusal: Codable, Equatable, Sendable {
    public let id: String
    public let appName: String?
    public let path: String?
    public let reason: String

    public init(id: String, appName: String? = nil, path: String? = nil, reason: String) {
        self.id = id
        self.appName = appName
        self.path = path
        self.reason = reason
    }
}

public struct RepairBackupRemovalPlan: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let volumeName: String
    public let volumePath: String
    public let requestedIDs: [String]
    public let selected: [RepairBackupEntry]
    public let refused: [RepairBackupRemovalRefusal]
    public let totalBytes: UInt64
    public let notes: [String]

    public var exitCode: Int32 {
        refused.isEmpty ? 0 : 1
    }

    public init(
        generatedAt: String,
        volumeName: String,
        volumePath: String,
        requestedIDs: [String],
        selected: [RepairBackupEntry],
        refused: [RepairBackupRemovalRefusal],
        totalBytes: UInt64,
        notes: [String]
    ) {
        self.generatedAt = generatedAt
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.requestedIDs = requestedIDs
        self.selected = selected
        self.refused = refused
        self.totalBytes = totalBytes
        self.notes = notes
    }
}

public struct RepairBackupRemovalFailure: Codable, Equatable, Sendable {
    public let id: String
    public let appName: String?
    public let path: String
    public let reason: String

    public init(id: String, appName: String? = nil, path: String, reason: String) {
        self.id = id
        self.appName = appName
        self.path = path
        self.reason = reason
    }
}

public struct RepairBackupRemovalResult: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let volumeName: String
    public let volumePath: String
    public let removed: [RepairBackupEntry]
    public let refused: [RepairBackupRemovalRefusal]
    public let failed: [RepairBackupRemovalFailure]
    public let reclaimedBytes: UInt64
    public let freeBytesBefore: UInt64?
    public let freeBytesAfter: UInt64?
    public let notes: [String]

    public var exitCode: Int32 {
        refused.isEmpty && failed.isEmpty ? 0 : 1
    }

    public init(
        generatedAt: String,
        volumeName: String,
        volumePath: String,
        removed: [RepairBackupEntry],
        refused: [RepairBackupRemovalRefusal],
        failed: [RepairBackupRemovalFailure],
        reclaimedBytes: UInt64,
        freeBytesBefore: UInt64?,
        freeBytesAfter: UInt64?,
        notes: [String]
    ) {
        self.generatedAt = generatedAt
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.removed = removed
        self.refused = refused
        self.failed = failed
        self.reclaimedBytes = reclaimedBytes
        self.freeBytesBefore = freeBytesBefore
        self.freeBytesAfter = freeBytesAfter
        self.notes = notes
    }
}
