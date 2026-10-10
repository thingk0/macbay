import Foundation
import MacBayKit

public protocol TUIServiceProtocol: Sendable {
    func isXcodeRunning() throws -> Bool
    func planXcode(volumePath: String, options: XcodeDoctorOptions) throws -> XcodeStoragePlan
    func executeXcode(plan: XcodeStoragePlan) throws -> XcodeDoctorReport
    func scanPurge() throws -> [PurgeItem]
    func executePurge(items: [PurgeItem]) throws -> PurgeReport
    func compareRepair(finding: DoctorFinding) throws -> RepairComparison
    func planRepair(comparison: RepairComparison, action: RepairAction) throws -> RepairPlan
    func executeRepair(plan: RepairPlan, force: Bool) throws -> RepairExecutionResult
    func previewRollback(finding: DoctorFinding) throws -> RepairJournalRecord
    func executeRollback(record: RepairJournalRecord) throws -> RepairExecutionResult
    func loadStatus() throws -> StatusReport
    func loadScan() throws -> ScanReport
    func loadDoctor(volumePath: String?) throws -> DoctorReport
    func eligibleVolumes() throws -> [StorageVolume]
    func defaultVolume() throws -> DefaultVolume?
    func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult
    func undock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult
    func explore(path: String) throws -> ExplorerScanReport
    func exploreMovePreview(path: String, volumePath: String?) throws -> MigrationResult
    func refreshExplorer(root: String, changedPaths: [String], droppedEvents: Bool) -> ExplorerRefreshResult?
    func move(
        path: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult
    func volumePath(containing path: String) -> String?
    func planAdopt(
        appName: String,
        volumePath: String,
        progress: ProgressHandler?
    ) throws -> AdoptPlan
    func executeAdopt(
        plan: AdoptPlan,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> AdoptExecutionResult
}

public extension TUIServiceProtocol {
    func isXcodeRunning() throws -> Bool { throw MacBayError.unsupportedOperation("Xcode storage is unavailable") }
    func planXcode(volumePath: String, options: XcodeDoctorOptions) throws -> XcodeStoragePlan { throw MacBayError.unsupportedOperation("Xcode storage is unavailable") }
    func executeXcode(plan: XcodeStoragePlan) throws -> XcodeDoctorReport { throw MacBayError.unsupportedOperation("Xcode storage is unavailable") }
    func scanPurge() throws -> [PurgeItem] { throw MacBayError.unsupportedOperation("Cache cleanup is unavailable") }
    func executePurge(items: [PurgeItem]) throws -> PurgeReport { throw MacBayError.unsupportedOperation("Cache cleanup is unavailable") }
    func compareRepair(finding: DoctorFinding) throws -> RepairComparison { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func planRepair(comparison: RepairComparison, action: RepairAction) throws -> RepairPlan { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func executeRepair(plan: RepairPlan, force: Bool) throws -> RepairExecutionResult { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func previewRollback(finding: DoctorFinding) throws -> RepairJournalRecord { throw MacBayError.unsupportedOperation("No supported repair journal is available") }
    func executeRollback(record: RepairJournalRecord) throws -> RepairExecutionResult { throw MacBayError.unsupportedOperation("Rollback is unavailable") }
}
