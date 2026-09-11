import Foundation
import MacBayKit

public protocol TUIServiceProtocol: Sendable {
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
