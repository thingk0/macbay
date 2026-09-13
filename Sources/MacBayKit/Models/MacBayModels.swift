import Foundation

public enum CandidateKind: String, Codable, Sendable {
    case application
    case developerCache
}

public enum DockedItemKind: String, Codable, Sendable {
    case application
    case xcode
    case cache
    case directory
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

public struct DefaultVolume: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let uuid: String?
    public let savedAt: String

    public init(path: String, name: String, uuid: String? = nil, savedAt: String) {
        self.path = path
        self.name = name
        self.uuid = uuid
        self.savedAt = savedAt
    }
}

public struct MacBayConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public var defaultVolume: DefaultVolume?

    public init(version: Int = MacBayConfig.currentVersion, defaultVolume: DefaultVolume? = nil) {
        self.version = version
        self.defaultVolume = defaultVolume
    }
}

public struct StatusDefaultVolume: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let uuid: String?
    public let mountedPath: String?

    public init(
        name: String,
        path: String,
        uuid: String? = nil,
        mountedPath: String? = nil
    ) {
        self.name = name
        self.path = path
        self.uuid = uuid
        self.mountedPath = mountedPath
    }
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let internalVolume: StorageVolume
    public let externalVolumes: [StorageVolume]
    public let defaultVolume: StatusDefaultVolume?
    public let dockedItems: [DockedItem]
    public let warnings: [String]

    public init(
        generatedAt: String,
        internalVolume: StorageVolume,
        externalVolumes: [StorageVolume],
        defaultVolume: StatusDefaultVolume? = nil,
        dockedItems: [DockedItem],
        warnings: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.internalVolume = internalVolume
        self.externalVolumes = externalVolumes
        self.defaultVolume = defaultVolume
        self.dockedItems = dockedItems
        self.warnings = warnings
    }
}

public struct InitReport: Codable, Equatable, Sendable {
    public let volume: StorageVolume
    public let configPath: String
    public let previousDefault: DefaultVolume?
    public let replaced: Bool

    public init(
        volume: StorageVolume,
        configPath: String,
        previousDefault: DefaultVolume? = nil,
        replaced: Bool
    ) {
        self.volume = volume
        self.configPath = configPath
        self.previousDefault = previousDefault
        self.replaced = replaced
    }
}

public struct ConfigReport: Codable, Equatable, Sendable {
    public let configPath: String
    public let defaultVolume: DefaultVolume?
    public let removedVolume: DefaultVolume?

    public init(
        configPath: String,
        defaultVolume: DefaultVolume? = nil,
        removedVolume: DefaultVolume? = nil
    ) {
        self.configPath = configPath
        self.defaultVolume = defaultVolume
        self.removedVolume = removedVolume
    }
}

public enum ExternalAppManagementStatus: String, Codable, Equatable, Sendable {
    case macBay
    case unmanaged
    case unconfirmed

    public var badge: String {
        switch self {
        case .macBay: return "[MacBay]"
        case .unmanaged: return "[Unmanaged]"
        case .unconfirmed: return "[Unconfirmed]"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw.lowercased() == "macbay" {
            self = .macBay
        } else if raw.lowercased() == "unmanaged" {
            self = .unmanaged
        } else {
            self = .unconfirmed
        }
    }
}

public struct ExternalApplication: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let sourcePath: String
    public let destinationPath: String
    public let sizeBytes: UInt64?
    public let managementStatus: ExternalAppManagementStatus

    public var id: String { sourcePath }

    public init(
        name: String,
        sourcePath: String,
        destinationPath: String,
        sizeBytes: UInt64?,
        managementStatus: ExternalAppManagementStatus
    ) {
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sizeBytes = sizeBytes
        self.managementStatus = managementStatus
    }
}

public struct UnresolvedApplicationLink: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let sourcePath: String
    public let destinationPath: String
    public let reason: String

    public var id: String { sourcePath }

    public init(
        name: String,
        sourcePath: String,
        destinationPath: String,
        reason: String
    ) {
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.reason = reason
    }
}

public struct ScanReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let minimumApplicationSizeBytes: UInt64
    public let candidates: [AppCandidate]
    public let externalApplications: [ExternalApplication]
    public let unresolvedApplicationLinks: [UnresolvedApplicationLink]
    public let warnings: [String]

    public init(
        generatedAt: String,
        minimumApplicationSizeBytes: UInt64,
        candidates: [AppCandidate],
        externalApplications: [ExternalApplication] = [],
        unresolvedApplicationLinks: [UnresolvedApplicationLink] = [],
        warnings: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.minimumApplicationSizeBytes = minimumApplicationSizeBytes
        self.candidates = candidates
        self.externalApplications = externalApplications
        self.unresolvedApplicationLinks = unresolvedApplicationLinks
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case minimumApplicationSizeBytes
        case candidates
        case externalApplications
        case unresolvedApplicationLinks
        case warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
        self.minimumApplicationSizeBytes = try container.decode(UInt64.self, forKey: .minimumApplicationSizeBytes)
        self.candidates = try container.decode([AppCandidate].self, forKey: .candidates)
        self.externalApplications = try container.decodeIfPresent([ExternalApplication].self, forKey: .externalApplications) ?? []
        self.unresolvedApplicationLinks = try container.decodeIfPresent([UnresolvedApplicationLink].self, forKey: .unresolvedApplicationLinks) ?? []
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
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
    public let archives: MigrationResult?
    public let derivedData: MigrationResult?
    public let simulatorCleanup: CommandResultSummary?
    public let derivedDataCleanup: CommandResultSummary?
    public let cacheCleanup: CommandResultSummary?
    public let freedBytes: UInt64

    public init(
        deviceSupport: MigrationResult? = nil,
        archives: MigrationResult? = nil,
        derivedData: MigrationResult? = nil,
        simulatorCleanup: CommandResultSummary? = nil,
        derivedDataCleanup: CommandResultSummary? = nil,
        cacheCleanup: CommandResultSummary? = nil,
        freedBytes: UInt64 = 0
    ) {
        self.deviceSupport = deviceSupport
        self.archives = archives
        self.derivedData = derivedData
        self.simulatorCleanup = simulatorCleanup
        self.derivedDataCleanup = derivedDataCleanup
        self.cacheCleanup = cacheCleanup
        self.freedBytes = freedBytes
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

public struct TeardownFailure: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct TeardownReport: Codable, Equatable, Sendable {
    public let restored: [MigrationResult]
    public let unlinkedCaches: [MigrationResult]
    public let failures: [TeardownFailure]
    public let cacheConfigurationReset: Bool
    public let defaultVolumeRemoved: Bool
    public let notes: [String]
    public let dryRun: Bool

    public var exitCode: Int32 {
        failures.isEmpty ? 0 : 1
    }

    public init(
        restored: [MigrationResult],
        unlinkedCaches: [MigrationResult],
        failures: [TeardownFailure],
        cacheConfigurationReset: Bool,
        defaultVolumeRemoved: Bool,
        notes: [String],
        dryRun: Bool
    ) {
        self.restored = restored
        self.unlinkedCaches = unlinkedCaches
        self.failures = failures
        self.cacheConfigurationReset = cacheConfigurationReset
        self.defaultVolumeRemoved = defaultVolumeRemoved
        self.notes = notes
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
    case configFailed(path: String, details: String)
    case unsupportedOperation(String)
    case unmanagedLinkDetected(path: String, targetPath: String)
    case compatibilityBlocked(path: String, assessment: CompatibilityAssessment)
    case forceRequired(path: String, assessment: CompatibilityAssessment)
    case insufficientSpace(path: String, neededBytes: UInt64, availableBytes: UInt64)
    case spaceCheckFailed(path: String, details: String)

    public var errorCode: String {
        switch self {
        case .compatibilityBlocked,
             .forceRequired,
             .invalidVolume,
             .externalVolumeRequired,
             .invalidApplication,
             .applicationAlreadyDocked,
             .unmanagedLinkDetected,
             .destinationExists,
             .pathMissing,
             .configFailed,
             .unsupportedOperation:
            return "configuration_error"
        case .activeProcesses,
             .sqliteLockDetected,
             .insufficientSpace:
            return "retryable_error"
        case .signatureVerificationFailed,
             .commandFailed,
             .manifestFailed,
             .spaceCheckFailed:
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
        case let .configFailed(_, details):
            return details
        case let .insufficientSpace(_, neededBytes, availableBytes):
            return "Need \(OutputFormatter.humanBytes(neededBytes)), available \(OutputFormatter.humanBytes(availableBytes))"
        case let .spaceCheckFailed(_, details):
            return details
        case let .unmanagedLinkDetected(path, targetPath):
            return "Link: \(path) -> \(targetPath)"
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
        case let .unmanagedLinkDetected(path, targetPath):
            return "Application is already a symlink pointing to external storage (\(targetPath)). To register it with MacBay, use 'mb adopt \"\(URL(fileURLWithPath: path).lastPathComponent)\"'."
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
        case let .configFailed(path, details):
            return "Configuration error at \(path): \(details). Run 'mb init --reset' to remove the saved configuration."
        case let .unsupportedOperation(message):
            return message
        case let .compatibilityBlocked(path, assessment):
            let summary = assessment.reasons.joined(separator: ", ")
            return "Application is blocked from migration (\(path))\(summary.isEmpty ? "" : ": \(summary)")"
        case let .forceRequired(path, assessment):
            let summary = assessment.reasons.joined(separator: ", ")
            return "Application has migration risks (\(path))\(summary.isEmpty ? "" : ": \(summary)"). Use --force to proceed."
        case let .insufficientSpace(path, neededBytes, availableBytes):
            return "Not enough space on \(path): need \(OutputFormatter.humanBytes(neededBytes)), available \(OutputFormatter.humanBytes(availableBytes))"
        case let .spaceCheckFailed(path, details):
            return "Unable to verify free space on \(path): \(details)"
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

public enum DoctorStatus: String, Codable, Equatable, Sendable {
    case healthy
    case needsAttention = "needs_attention"
    case unableToVerify = "unable_to_verify"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "healthy":
            self = .healthy
        case "needs_attention":
            self = .needsAttention
        default:
            self = .unableToVerify
        }
    }
}

public enum DoctorCategory: String, Codable, Equatable, Sendable {
    case applicationLink = "application_link"
    case developerDataLink = "developer_data_link"
    case dataLink = "data_link"
    case record
    case externalReference = "external_reference"
    case volume
}

public enum DoctorCode: String, Codable, Equatable, Sendable {
    case linkManagedRecord = "link_managed_record"
    case linkManagedLayout = "link_managed_layout"
    case linkUnmanaged = "link_unmanaged"
    case linkTargetUnavailable = "link_target_unavailable"
    case linkCircular = "link_circular"
    case linkRecordMismatch = "link_record_mismatch"
    case recordTargetMissing = "record_target_missing"
    case recordSourceMissing = "record_source_missing"
    case localDataDetected = "local_data_detected"
    case linkTargetUnverified = "link_target_unverified"
    case linkUnreadable = "link_unreadable"
    case applicationsUnreadable = "applications_unreadable"
    case manifestUnreadable = "manifest_unreadable"
    case manifestVersionUnsupported = "manifest_version_unsupported"
    case defaultVolumeMounted = "default_volume_mounted"
    case defaultVolumeUnavailable = "default_volume_unavailable"
    case defaultVolumeIneligible = "default_volume_ineligible"
    case configUnreadable = "config_unreadable"
    case incompleteOperation = "incomplete_operation"
    case externalReferenceStaleCandidate = "external_reference_stale_candidate"
    case externalReferenceUnverified = "external_reference_unverified"
    case externalReferenceMissing = "external_reference_missing"
    case externalReferenceScanIncomplete = "external_reference_scan_incomplete"
    case externalConfigUnreadable = "external_config_unreadable"
    case externalConfigPartiallyChecked = "external_config_partially_checked"
}

public struct DoctorFinding: Codable, Equatable, Identifiable, Sendable {
    public let code: DoctorCode
    public let status: DoctorStatus
    public let category: DoctorCategory
    public let name: String
    public let paths: [String]
    public let referenceLocations: [String]?
    public let detail: String
    public let recommendation: String
    public let managed: Bool?
    public let localSizeBytes: UInt64?
    public let externalSizeBytes: UInt64?

    public var id: String { "\(code.rawValue)|\(paths.joined(separator: "|"))" }

    public init(
        code: DoctorCode,
        status: DoctorStatus,
        category: DoctorCategory,
        name: String,
        paths: [String],
        detail: String,
        recommendation: String,
        managed: Bool? = nil,
        localSizeBytes: UInt64? = nil,
        externalSizeBytes: UInt64? = nil,
        referenceLocations: [String]? = nil
    ) {
        self.code = code
        self.status = status
        self.category = category
        self.name = name
        self.paths = paths
        self.referenceLocations = referenceLocations
        self.detail = detail
        self.recommendation = recommendation
        self.managed = managed
        self.localSizeBytes = localSizeBytes
        self.externalSizeBytes = externalSizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case code, status, category, name, paths, referenceLocations
        case detail, recommendation, managed, localSizeBytes, externalSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(DoctorCode.self, forKey: .code)
        self.status = try container.decode(DoctorStatus.self, forKey: .status)
        self.category = try container.decode(DoctorCategory.self, forKey: .category)
        self.name = try container.decode(String.self, forKey: .name)
        self.paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        self.referenceLocations = try container.decodeIfPresent([String].self, forKey: .referenceLocations)
        self.detail = try container.decode(String.self, forKey: .detail)
        self.recommendation = try container.decodeIfPresent(String.self, forKey: .recommendation) ?? ""
        self.managed = try container.decodeIfPresent(Bool.self, forKey: .managed)
        self.localSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .localSizeBytes)
        self.externalSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .externalSizeBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(status, forKey: .status)
        try container.encode(category, forKey: .category)
        try container.encode(name, forKey: .name)
        try container.encode(paths, forKey: .paths)
        try container.encodeIfPresent(referenceLocations, forKey: .referenceLocations)
        try container.encode(detail, forKey: .detail)
        try container.encode(recommendation, forKey: .recommendation)
        try container.encode(managed, forKey: .managed)
        try container.encode(localSizeBytes, forKey: .localSizeBytes)
        try container.encode(externalSizeBytes, forKey: .externalSizeBytes)
    }
}

public enum DoctorManifestStatus: String, Codable, Equatable, Sendable {
    case loaded
    case missing
    case unreadable
    case unsupportedVersion = "unsupported_version"
}

public struct DoctorVolumeScope: Codable, Equatable, Sendable {
    public let name: String
    public let mountPoint: String
    public let manifestPath: String
    public let isReadOnly: Bool
    public let manifestStatus: DoctorManifestStatus
    public let recordCount: Int

    public init(
        name: String,
        mountPoint: String,
        manifestPath: String,
        isReadOnly: Bool,
        manifestStatus: DoctorManifestStatus,
        recordCount: Int
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.manifestPath = manifestPath
        self.isReadOnly = isReadOnly
        self.manifestStatus = manifestStatus
        self.recordCount = recordCount
    }
}

public struct DoctorSummary: Codable, Equatable, Sendable {
    public let checked: Int
    public let healthy: Int
    public let unmanaged: Int
    public let needsAttention: Int
    public let unableToVerify: Int

    public init(
        checked: Int,
        healthy: Int,
        unmanaged: Int,
        needsAttention: Int,
        unableToVerify: Int
    ) {
        self.checked = checked
        self.healthy = healthy
        self.unmanaged = unmanaged
        self.needsAttention = needsAttention
        self.unableToVerify = unableToVerify
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let volumes: [DoctorVolumeScope]
    public let findings: [DoctorFinding]
    public let summary: DoctorSummary
    public let warnings: [String]
    public let notes: [String]

    public var exitCode: Int32 {
        summary.needsAttention + summary.unableToVerify > 0 ? 1 : 0
    }

    public init(
        generatedAt: String,
        volumes: [DoctorVolumeScope],
        findings: [DoctorFinding],
        summary: DoctorSummary,
        warnings: [String],
        notes: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.volumes = volumes
        self.findings = findings
        self.summary = summary
        self.warnings = warnings
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, volumes, findings, summary, warnings, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
        self.volumes = try container.decodeIfPresent([DoctorVolumeScope].self, forKey: .volumes) ?? []
        self.findings = try container.decodeIfPresent([DoctorFinding].self, forKey: .findings) ?? []
        self.summary = try container.decode(DoctorSummary.self, forKey: .summary)
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public func macBayTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

public struct AdoptOperationRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case started
        case appMoved = "app_moved"
        case linkReplaced = "link_replaced"
        case registering
        case completed
    }

    public let id: String
    public let appName: String
    public let sourcePath: String
    public let originalExternalPath: String
    public let targetExternalPath: String
    public let originalLinkTarget: String
    public let volumePath: String
    public var phase: Phase
    public let timestamp: String

    public init(
        id: String,
        appName: String,
        sourcePath: String,
        originalExternalPath: String,
        targetExternalPath: String,
        originalLinkTarget: String,
        volumePath: String,
        phase: Phase,
        timestamp: String
    ) {
        self.id = id
        self.appName = appName
        self.sourcePath = sourcePath
        self.originalExternalPath = originalExternalPath
        self.targetExternalPath = targetExternalPath
        self.originalLinkTarget = originalLinkTarget
        self.volumePath = volumePath
        self.phase = phase
        self.timestamp = timestamp
    }

    public func updatingPhase(_ newPhase: Phase) -> AdoptOperationRecord {
        AdoptOperationRecord(
            id: id,
            appName: appName,
            sourcePath: sourcePath,
            originalExternalPath: originalExternalPath,
            targetExternalPath: targetExternalPath,
            originalLinkTarget: originalLinkTarget,
            volumePath: volumePath,
            phase: newPhase,
            timestamp: timestamp
        )
    }
}

