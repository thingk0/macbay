import Foundation

public enum RepairBackupFileKind: Equatable, Sendable {
    case missing
    case file
    case directory
    case symbolicLink
    case unreadable
}

public struct RepairBackupBundleMetadata: Equatable, Sendable {
    public let version: String?
    public let buildNumber: String?
    public let isVerifiable: Bool
    public let reason: String?

    public init(
        version: String? = nil,
        buildNumber: String? = nil,
        isVerifiable: Bool,
        reason: String? = nil
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.isVerifiable = isVerifiable
        self.reason = reason
    }
}

public struct RepairBackupJournalFile: Equatable, Sendable {
    public let path: String
    public let contents: String?

    public init(path: String, contents: String?) {
        self.path = path
        self.contents = contents
    }
}

public struct RepairBackupJournalScan: Equatable, Sendable {
    public let files: [RepairBackupJournalFile]
    public let isComplete: Bool
    public let warnings: [String]

    public init(
        files: [RepairBackupJournalFile],
        isComplete: Bool,
        warnings: [String] = []
    ) {
        self.files = files
        self.isComplete = isComplete
        self.warnings = warnings
    }
}

public protocol RepairBackupFileSystem: Sendable {
    func kind(of url: URL) -> RepairBackupFileKind
    func directoryEntries(at url: URL) throws -> [URL]
    func size(of url: URL) throws -> UInt64
    func bundleMetadata(at url: URL) -> RepairBackupBundleMetadata
    func creationDate(of url: URL) -> Date?
    func removeItem(at url: URL) throws
    func isDirectoryEmpty(at url: URL) throws -> Bool
    func availableBytes(on volume: URL) throws -> UInt64
    func journalFiles(on volume: URL) -> RepairBackupJournalScan
}

public protocol RepairBackupUseCaseProtocol: Sendable {
    func inventory(on volume: URL, volumeName: String) throws -> RepairBackupInventory
    func planRemoval(
        ids: [String],
        on volume: URL,
        volumeName: String
    ) throws -> RepairBackupRemovalPlan
    func execute(
        plan: RepairBackupRemovalPlan,
        progress: ProgressHandler?
    ) throws -> RepairBackupRemovalResult
}
