import Foundation

public enum CandidateKind: String, Codable, Sendable {
    case application
    case developerCache
}

public enum DockedItemKind: String, Codable, Sendable {
    case application
    case xcode
    case cache
}

public struct StorageVolume: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let isInternal: Bool
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public var id: String { path }

    public var usedBytes: UInt64 {
        totalBytes >= availableBytes ? totalBytes - availableBytes : 0
    }

    public var availablePercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(availableBytes) / Double(totalBytes) * 100
    }

    public init(
        name: String,
        path: String,
        isInternal: Bool,
        totalBytes: UInt64,
        availableBytes: UInt64
    ) {
        self.name = name
        self.path = path
        self.isInternal = isInternal
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public enum CompatibilityGrade: String, Codable, Equatable, Sendable {
    case safe
    case popupRisk
    case blocked
}

public struct CompatibilityAssessment: Codable, Equatable, Sendable {
    public let grade: CompatibilityGrade
    public let reasons: [String]
    public let evidence: [String]

    public init(
        grade: CompatibilityGrade,
        reasons: [String] = [],
        evidence: [String] = []
    ) {
        self.grade = grade
        self.reasons = reasons
        self.evidence = evidence
    }
}

public struct AppCandidate: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let sizeBytes: UInt64
    public let kind: CandidateKind
    public let compatibility: CompatibilityAssessment?

    public var id: String { path }

    public init(
        name: String,
        path: String,
        sizeBytes: UInt64,
        kind: CandidateKind,
        compatibility: CompatibilityAssessment? = nil
    ) {
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.compatibility = compatibility
    }
}

public struct DockedItem: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let sourcePath: String
    public let externalPath: String
    public let sizeBytes: UInt64
    public let kind: DockedItemKind
    public let dockedAt: String

    public var id: String { sourcePath }

    public init(
        name: String,
        sourcePath: String,
        externalPath: String,
        sizeBytes: UInt64,
        kind: DockedItemKind,
        dockedAt: String
    ) {
        self.name = name
        self.sourcePath = sourcePath
        self.externalPath = externalPath
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.dockedAt = dockedAt
    }
}

public struct DockManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public var items: [DockedItem]

    public init(version: Int = DockManifest.currentVersion, items: [DockedItem] = []) {
        self.version = version
        self.items = items
    }
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let internalVolume: StorageVolume
    public let externalVolumes: [StorageVolume]
    public let dockedItems: [DockedItem]
    public let warnings: [String]

    public init(
        generatedAt: String,
        internalVolume: StorageVolume,
        externalVolumes: [StorageVolume],
        dockedItems: [DockedItem],
        warnings: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.internalVolume = internalVolume
        self.externalVolumes = externalVolumes
        self.dockedItems = dockedItems
        self.warnings = warnings
    }
}

public struct ScanReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let minimumApplicationSizeBytes: UInt64
    public let candidates: [AppCandidate]
    public let warnings: [String]

    public init(
        generatedAt: String,
        minimumApplicationSizeBytes: UInt64,
        candidates: [AppCandidate],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.minimumApplicationSizeBytes = minimumApplicationSizeBytes
        self.candidates = candidates
        self.warnings = warnings
    }
}

public struct ProcessLock: Codable, Equatable, Sendable {
    public let process: String
    public let pid: Int32
    public let user: String
    public let fileDescriptor: String
    public let path: String

    public init(process: String, pid: Int32, user: String, fileDescriptor: String, path: String) {
        self.process = process
        self.pid = pid
        self.user = user
        self.fileDescriptor = fileDescriptor
        self.path = path
    }
}

public struct SQLiteLock: Codable, Equatable, Sendable {
    public let databasePath: String
    public let lockPath: String

    public init(databasePath: String, lockPath: String) {
        self.databasePath = databasePath
        self.lockPath = lockPath
    }
}

public struct ProcessInspection: Codable, Equatable, Sendable {
    public let path: String
    public let processLocks: [ProcessLock]
    public let sqliteLocks: [SQLiteLock]

    public var isSafeToMove: Bool {
        processLocks.isEmpty && sqliteLocks.isEmpty
    }

    public init(path: String, processLocks: [ProcessLock], sqliteLocks: [SQLiteLock]) {
        self.path = path
        self.processLocks = processLocks
        self.sqliteLocks = sqliteLocks
    }
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct MigrationResult: Codable, Equatable, Sendable {
    public let operation: String
    public let name: String
    public let sourcePath: String
    public let destinationPath: String
    public let sizeBytes: UInt64
    public let dryRun: Bool
    public let messages: [String]
    public let compatibility: CompatibilityAssessment?

    public init(
        operation: String,
        name: String,
        sourcePath: String,
        destinationPath: String,
        sizeBytes: UInt64,
        dryRun: Bool,
        messages: [String],
        compatibility: CompatibilityAssessment? = nil
    ) {
        self.operation = operation
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sizeBytes = sizeBytes
        self.dryRun = dryRun
        self.messages = messages
        self.compatibility = compatibility
    }
}

public struct XcodeDoctorReport: Codable, Equatable, Sendable {
    public let deviceSupport: MigrationResult?
    public let simulatorCleanup: CommandResultSummary?

    public init(deviceSupport: MigrationResult?, simulatorCleanup: CommandResultSummary?) {
        self.deviceSupport = deviceSupport
        self.simulatorCleanup = simulatorCleanup
    }
}

public struct CommandResultSummary: Codable, Equatable, Sendable {
    public let command: String
    public let succeeded: Bool
    public let output: String

    public init(command: String, succeeded: Bool, output: String) {
        self.command = command
        self.succeeded = succeeded
        self.output = output
    }
}

public struct CacheReport: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let reset: Bool
    public let targets: [MigrationResult]
    public let shellConfigurationPath: String
    public let dryRun: Bool

    public init(
        enabled: Bool,
        reset: Bool,
        targets: [MigrationResult],
        shellConfigurationPath: String,
        dryRun: Bool
    ) {
        self.enabled = enabled
        self.reset = reset
        self.targets = targets
        self.shellConfigurationPath = shellConfigurationPath
        self.dryRun = dryRun
    }
}

public enum MacBayError: Error, Equatable, LocalizedError, Sendable {
    case invalidVolume(String)
    case externalVolumeRequired(String)
    case invalidApplication(String)
    case applicationAlreadyDocked(String)
    case destinationExists(String)
    case pathMissing(String)
    case activeProcesses(path: String, locks: [ProcessLock])
    case sqliteLockDetected(path: String, locks: [SQLiteLock])
    case signatureVerificationFailed(path: String, details: String)
    case commandFailed(executable: String, status: Int32, details: String)
    case manifestFailed(path: String, details: String)
    case unsupportedOperation(String)
    case compatibilityBlocked(path: String, assessment: CompatibilityAssessment)
    case forceRequired(path: String, assessment: CompatibilityAssessment)

    public var errorCode: String {
        switch self {
        case .compatibilityBlocked,
             .forceRequired,
             .invalidVolume,
             .externalVolumeRequired,
             .invalidApplication,
             .applicationAlreadyDocked,
             .destinationExists,
             .pathMissing,
             .unsupportedOperation:
            return "configuration_error"
        case .activeProcesses,
             .sqliteLockDetected:
            return "retryable_error"
        case .signatureVerificationFailed,
             .commandFailed,
             .manifestFailed:
            return "execution_error"
        }
    }

    public var errorDetails: String {
        switch self {
        case let .compatibilityBlocked(_, assessment):
            let reasons = assessment.reasons.joined(separator: "; ")
            let evidence = assessment.evidence.joined(separator: "; ")
            return [reasons, evidence].filter { !$0.isEmpty }.joined(separator: " | ")
        case let .forceRequired(_, assessment):
            let reasons = assessment.reasons.joined(separator: "; ")
            let evidence = assessment.evidence.joined(separator: "; ")
            return [reasons, evidence].filter { !$0.isEmpty }.joined(separator: " | ")
        case let .activeProcesses(_, locks):
            return locks.map { "\($0.process) (\($0.pid))" }.joined(separator: ", ")
        case let .sqliteLockDetected(_, locks):
            return locks.map(\.lockPath).joined(separator: ", ")
        case let .signatureVerificationFailed(_, details):
            return details
        case let .commandFailed(_, _, details):
            return details
        case let .manifestFailed(_, details):
            return details
        case let .invalidVolume(details),
             let .externalVolumeRequired(details),
             let .invalidApplication(details),
             let .applicationAlreadyDocked(details),
             let .destinationExists(details),
             let .pathMissing(details),
             let .unsupportedOperation(details):
            return details
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidVolume(path):
            return "Invalid volume: \(path)"
        case let .externalVolumeRequired(path):
            return "An external volume is required: \(path)"
        case let .invalidApplication(path):
            return "Invalid application bundle: \(path)"
        case let .applicationAlreadyDocked(path):
            return "Application is already docked: \(path)"
        case let .destinationExists(path):
            return "Destination already exists: \(path)"
        case let .pathMissing(path):
            return "Path does not exist: \(path)"
        case let .activeProcesses(path, locks):
            let processes = locks.map { "\($0.process) (\($0.pid))" }.joined(separator: ", ")
            return "Active processes are using \(path): \(processes)"
        case let .sqliteLockDetected(path, locks):
            let lockPaths = locks.map(\.lockPath).joined(separator: ", ")
            return "SQLite lock files are present under \(path): \(lockPaths)"
        case let .signatureVerificationFailed(path, details):
            return "Code signature verification failed for \(path): \(details)"
        case let .commandFailed(executable, status, details):
            return "Command failed (\(status)): \(executable)\(details.isEmpty ? "" : " — \(details)")"
        case let .manifestFailed(path, details):
            return "Manifest error at \(path): \(details)"
        case let .unsupportedOperation(message):
            return message
        case let .compatibilityBlocked(path, assessment):
            let summary = assessment.reasons.joined(separator: ", ")
            return "Application is blocked from migration (\(path))\(summary.isEmpty ? "" : ": \(summary)")"
        case let .forceRequired(path, assessment):
            let summary = assessment.reasons.joined(separator: ", ")
            return "Application has migration risks (\(path))\(summary.isEmpty ? "" : ": \(summary)"). Use --force to proceed."
        }
    }
}

public struct MacBayErrorPayload: Codable, Equatable, Sendable {
    public struct ErrorBody: Codable, Equatable, Sendable {
        public let code: String
        public let message: String
        public let details: String

        public init(code: String, message: String, details: String) {
            self.code = code
            self.message = message
            self.details = details
        }
    }

    public let error: ErrorBody

    public init(code: String, message: String, details: String) {
        self.error = ErrorBody(code: code, message: message, details: details)
    }

    public init(error: Error) {
        if let macBayError = error as? MacBayError {
            self.init(
                code: macBayError.errorCode,
                message: macBayError.errorDescription ?? "\(error)",
                details: macBayError.errorDetails
            )
        } else {
            self.init(
                code: "configuration_error",
                message: error.localizedDescription,
                details: ""
            )
        }
    }
}

public func macBayTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}
