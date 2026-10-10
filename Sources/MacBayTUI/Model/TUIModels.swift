import Foundation
import MacBayKit

public enum PurgeListRow: Equatable {
    case application(PurgeAppGroup)
    case target(PurgeItem)

    public var eligibleItems: [PurgeItem] {
        switch self {
        case .application(let group): return group.items.filter { !$0.isRunning }
        case .target(let item): return item.isRunning ? [] : [item]
        }
    }
}

public struct PurgePreview: Equatable {
    public let items: [PurgeItem]
    public let skippedItems: [PurgeItem]
    public var sizeBytes: UInt64 { items.reduce(0) { $0 + $1.sizeBytes } }

    public init(items: [PurgeItem], skippedItems: [PurgeItem]) {
        self.items = items
        self.skippedItems = skippedItems
    }
}

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
    public let notice: String?

    public init(
        appName: String,
        operation: String,
        sourcePath: String,
        destinationPath: String,
        sizeBytes: UInt64,
        volumePath: String?,
        force: Bool,
        messages: [String],
        compatibility: CompatibilityAssessment? = nil,
        notice: String? = nil
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
        self.notice = notice
    }
}

public struct AdoptOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case completed
        case failed(stage: String?, message: String)
    }

    public let appName: String
    public let status: Status
    public let mode: AdoptMode?
    public let sizeBytes: UInt64?
    public let currentLocation: String?
    public let destinationPath: String?
    public let volumePath: String?
    public let rollbackActions: [String]
    public let rollbackError: String?
    public let manualInterventionNeeded: [String]
    public let errorDetails: String?
    public var restorePreviewError: String?

    public init(
        appName: String,
        status: Status,
        mode: AdoptMode? = nil,
        sizeBytes: UInt64? = nil,
        currentLocation: String? = nil,
        destinationPath: String? = nil,
        volumePath: String? = nil,
        rollbackActions: [String] = [],
        rollbackError: String? = nil,
        manualInterventionNeeded: [String] = [],
        errorDetails: String? = nil,
        restorePreviewError: String? = nil
    ) {
        self.appName = appName
        self.status = status
        self.mode = mode
        self.sizeBytes = sizeBytes
        self.currentLocation = currentLocation
        self.destinationPath = destinationPath
        self.volumePath = volumePath
        self.rollbackActions = rollbackActions
        self.rollbackError = rollbackError
        self.manualInterventionNeeded = manualInterventionNeeded
        self.errorDetails = errorDetails
        self.restorePreviewError = restorePreviewError
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

public enum RecoveryView: Equatable {
    case comparison(RepairComparison)
    case preview(RepairPlan)
    case rollback(RepairJournalRecord)
    case result(String)
}

/// A move (dock) or restore (undock) applied to several applications chosen in one list.
public enum BatchOperation: String, Equatable, Sendable {
    case dock
    case undock

    public var verb: String { self == .dock ? "Move" : "Restore" }
    public var pastTense: String { self == .dock ? "moved" : "restored" }
}

/// One selected application in a batch preview. An entry with an `exclusion` is never executed.
public struct BatchPreviewItem: Equatable, Sendable {
    public let appName: String
    public let listPath: String
    public let preview: MigrationResult?
    public let compatibility: CompatibilityAssessment?
    public let exclusion: String?

    public var isIncluded: Bool { exclusion == nil && preview != nil }
    public var requiresRiskAcceptance: Bool { isIncluded && compatibility?.grade == .popupRisk }

    public init(
        appName: String,
        listPath: String,
        preview: MigrationResult?,
        compatibility: CompatibilityAssessment?,
        exclusion: String?
    ) {
        self.appName = appName
        self.listPath = listPath
        self.preview = preview
        self.compatibility = compatibility
        self.exclusion = exclusion
    }
}

public struct BatchPreview: Equatable, Sendable {
    public let operation: BatchOperation
    /// Destination volume for a move; restores resolve each app's own volume like the single-app flow.
    public let volumePath: String?
    public let items: [BatchPreviewItem]
    /// Free space where the batch writes, or nil when it could not be read.
    public let availableBytes: UInt64?

    public var included: [BatchPreviewItem] { items.filter(\.isIncluded) }
    public var excluded: [BatchPreviewItem] { items.filter { !$0.isIncluded } }
    public var riskItems: [BatchPreviewItem] { items.filter(\.requiresRiskAcceptance) }
    public var requiredBytes: UInt64 { included.reduce(0) { $0 + ($1.preview?.sizeBytes ?? 0) } }
    public var shortfallBytes: UInt64 {
        guard let availableBytes, requiredBytes > availableBytes else { return 0 }
        return requiredBytes - availableBytes
    }
    public var canProceed: Bool { !included.isEmpty && shortfallBytes == 0 }

    public init(operation: BatchOperation, volumePath: String?, items: [BatchPreviewItem], availableBytes: UInt64?) {
        self.operation = operation
        self.volumePath = volumePath
        self.items = items
        self.availableBytes = availableBytes
    }
}

public struct BatchItemResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case succeeded(MigrationResult)
        case failed(message: String, details: String?)
        case notStarted
    }

    public let appName: String
    public let status: Status

    public init(appName: String, status: Status) {
        self.appName = appName
        self.status = status
    }
}

public struct BatchReport: Equatable, Sendable {
    public let operation: BatchOperation
    public let results: [BatchItemResult]
    public let excluded: [BatchPreviewItem]

    public var succeededCount: Int { results.filter { if case .succeeded = $0.status { return true }; return false }.count }
    public var failedCount: Int { results.filter { if case .failed = $0.status { return true }; return false }.count }
    public var notStartedCount: Int { results.filter { $0.status == .notStarted }.count }
    public var allSucceeded: Bool { !results.isEmpty && succeededCount == results.count }

    public init(operation: BatchOperation, results: [BatchItemResult], excluded: [BatchPreviewItem]) {
        self.operation = operation
        self.results = results
        self.excluded = excluded
    }
}
