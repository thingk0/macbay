import Foundation
import MacBayKit

public enum RestoreStatus: Equatable, Sendable {
    case managed
    case unmanaged
    case unconfirmed
    case unresolved(reason: String)

    public var badge: String {
        switch self {
        case .managed: return "[Managed]"
        case .unmanaged: return "[Unmanaged]"
        case .unconfirmed: return "[Unconfirmed]"
        case .unresolved: return "[Unresolved]"
        }
    }
}

public struct RestoreItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sourcePath: String
    public let externalPath: String
    public let sizeBytes: UInt64?
    public let status: RestoreStatus

    public var isRestorable: Bool {
        status == .managed
    }

    public init(
        name: String,
        sourcePath: String,
        externalPath: String,
        sizeBytes: UInt64?,
        status: RestoreStatus
    ) {
        self.id = sourcePath
        self.name = name
        self.sourcePath = sourcePath
        self.externalPath = externalPath
        self.sizeBytes = sizeBytes
        self.status = status
    }
}

public struct MigrationPlanPreview: Equatable, Sendable {
    public let appName: String
    public let operation: String
    public let sourcePath: String
    public let destinationPath: String
    public let sizeBytes: UInt64
    public let volumePath: String?
    public let force: Bool
    public let messages: [String]
    public let compatibility: CompatibilityAssessment?

    public init(
        appName: String,
        operation: String,
        sourcePath: String,
        destinationPath: String,
        sizeBytes: UInt64,
        volumePath: String?,
        force: Bool,
        messages: [String],
        compatibility: CompatibilityAssessment? = nil
    ) {
        self.appName = appName
        self.operation = operation
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sizeBytes = sizeBytes
        self.volumePath = volumePath
        self.force = force
        self.messages = messages
        self.compatibility = compatibility
    }
}

public struct CompletedStep: Equatable, Sendable {
    public let label: String
    public let duration: TimeInterval

    public init(label: String, duration: TimeInterval) {
        self.label = label
        self.duration = duration
    }
}
