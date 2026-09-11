import Foundation

public enum AdoptMode: String, Codable, Equatable, Sendable {
    case moveAndAdopt
    case registerOnly
    case alreadyAdopted
}

public enum AdoptPlanStatus: Equatable, Sendable, Codable {
    case ready
    case reviewRequired(reasons: [String], evidence: [String])
    case blocked(reason: String, solution: String)
    case alreadyAdopted(details: String)
    case conflict(reason: String)
}

public struct PreflightStepRecord: Codable, Equatable, Sendable {
    public let name: String
    public let durationSeconds: Double

    public init(name: String, durationSeconds: Double) {
        self.name = name
        self.durationSeconds = durationSeconds
    }
}

public struct AdoptPlan: Codable, Equatable, Sendable {
    public let appName: String
    public let sourceURL: URL
    public let targetURL: URL
    public let destinationURL: URL
    public let symlinkURL: URL
    public let volumeURL: URL
    public let mode: AdoptMode
    public let status: AdoptPlanStatus
    public let sizeBytes: UInt64
    public let compatibility: CompatibilityAssessment
    public let steps: [PreflightStepRecord]

    public init(
        appName: String,
        sourceURL: URL,
        targetURL: URL,
        destinationURL: URL,
        symlinkURL: URL,
        volumeURL: URL,
        mode: AdoptMode,
        status: AdoptPlanStatus,
        sizeBytes: UInt64,
        compatibility: CompatibilityAssessment,
        steps: [PreflightStepRecord] = []
    ) {
        self.appName = appName
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.destinationURL = destinationURL
        self.symlinkURL = symlinkURL
        self.volumeURL = volumeURL
        self.mode = mode
        self.status = status
        self.sizeBytes = sizeBytes
        self.compatibility = compatibility
        self.steps = steps
    }
}

public enum RollbackStatus: Codable, Equatable, Sendable {
    case notRequired
    case succeeded(actions: [String])
    case failed(error: String, manualInterventionNeeded: [String])
}

public struct AdoptExecutionResult: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case completed
        case noChanges(reason: String)
        case failed(stage: String, error: String, rollback: RollbackStatus)
    }

    public let outcome: Outcome
    public let appName: String
    public let sourcePath: String
    public let destinationPath: String
    public let symlinkPath: String
    public let sizeBytes: UInt64
    public let mode: AdoptMode
    public let rollback: RollbackStatus

    public init(
        outcome: Outcome,
        appName: String,
        sourcePath: String,
        destinationPath: String,
        symlinkPath: String,
        sizeBytes: UInt64,
        mode: AdoptMode,
        rollback: RollbackStatus = .notRequired
    ) {
        self.outcome = outcome
        self.appName = appName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.symlinkPath = symlinkPath
        self.sizeBytes = sizeBytes
        self.mode = mode
        self.rollback = rollback
    }
}

public struct AdoptExecutionError: LocalizedError, Equatable, Sendable {
    public let stage: String
    public let message: String
    public let rollback: RollbackStatus

    public init(stage: String, message: String, rollback: RollbackStatus) {
        self.stage = stage
        self.message = message
        self.rollback = rollback
    }

    public init(stage: String, underlyingError: Error, rollback: RollbackStatus) {
        let desc = (underlyingError as? LocalizedError)?.errorDescription ?? underlyingError.localizedDescription
        self.init(stage: stage, message: desc, rollback: rollback)
    }

    public var errorDescription: String? {
        "Adopt failed at \(stage): \(message)"
    }
}
