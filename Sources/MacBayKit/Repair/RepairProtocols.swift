import Foundation

public protocol RepairSafetyInspector: Sendable {
    func inspectBundle(at url: URL) throws -> AppCopyInfo
    func assertSafeToOperate(at urls: [URL]) throws
    func assessCompatibility(at url: URL) -> CompatibilityAssessment
}

public protocol RepairBundleOperations: Sendable {
    func fileExists(at url: URL) -> Bool
    func isSymbolicLink(at url: URL) -> Bool
    func calculateSizeBytes(at url: URL) throws -> UInt64
    func copyBundle(from source: URL, to destination: URL) throws
    func moveBundle(from source: URL, to destination: URL) throws
    func remove(at url: URL) throws
    func createSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws
}

public protocol RepairManifestRepository: Sendable {
    func findItem(named appName: String, on volume: URL) throws -> DockedItem?
    func removeItem(named appName: String, on volume: URL) throws
    func recordItem(_ item: DockedItem, on volume: URL) throws
}

public protocol RepairJournaling: Sendable {
    func save(_ record: RepairJournalRecord, on volume: URL) throws
    func load(appName: String, on volume: URL) -> RepairJournalRecord?
    func remove(appName: String, on volume: URL)
    func listIncomplete(on volume: URL) -> [RepairJournalRecord]
}

public protocol RepairVolumeInspector: Sendable {
    func availableBytes(on volume: URL) throws -> UInt64
    func isWritable(volume: URL) -> Bool
}

public protocol RepairAppUseCaseProtocol: Sendable {
    func compare(appName: String, on volume: URL) throws -> RepairComparison
    func plan(appName: String, action: RepairAction, on volume: URL, progress: (@Sendable (String) -> Void)?) throws -> RepairPlan
    func execute(plan: RepairPlan, force: Bool, progress: (@Sendable (String) -> Void)?) throws -> RepairExecutionResult
    func rollback(appName: String, on volume: URL, progress: (@Sendable (String) -> Void)?) throws -> RepairExecutionResult
}

