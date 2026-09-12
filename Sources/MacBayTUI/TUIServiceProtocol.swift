import Foundation
import MacBayKit

public protocol TUIServiceProtocol: Sendable {
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
    func compareRepair(finding: DoctorFinding) throws -> RepairComparison { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func planRepair(comparison: RepairComparison, action: RepairAction) throws -> RepairPlan { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func executeRepair(plan: RepairPlan, force: Bool) throws -> RepairExecutionResult { throw MacBayError.unsupportedOperation("Repair is unavailable") }
    func previewRollback(finding: DoctorFinding) throws -> RepairJournalRecord { throw MacBayError.unsupportedOperation("No supported repair journal is available") }
    func executeRollback(record: RepairJournalRecord) throws -> RepairExecutionResult { throw MacBayError.unsupportedOperation("Rollback is unavailable") }
}
