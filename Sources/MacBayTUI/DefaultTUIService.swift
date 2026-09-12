import Foundation
import MacBayKit

public struct DefaultTUIService: @unchecked Sendable, TUIServiceProtocol {
    private let fileManager: FileManager
    private let service: MacBayService
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let applicationDirectories: [URL]?

    public init(
        fileManager: FileManager = .default,
        service: MacBayService? = nil,
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil,
        applicationDirectories: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.service = service ?? MacBayService(fileManager: fileManager)
        self.volumeManager = volumeManager ?? VolumeManager(fileManager: fileManager)
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.applicationDirectories = applicationDirectories
    }

    private func recoveryVolume(finding: DoctorFinding) throws -> String {
        guard finding.paths.count >= 2 else { throw MacBayError.unsupportedOperation("Missing external path") }
        var path = URL(fileURLWithPath: finding.paths[1]).standardizedFileURL
        while !fileManager.fileExists(atPath: path.path), path.path != "/" { path.deleteLastPathComponent() }
        guard let volume = volumePath(containing: path.path),
              try eligibleVolumes().contains(where: { $0.path == volume }) else {
            throw MacBayError.invalidVolume("Connect the external drive for this finding and refresh diagnosis.")
        }
        return volume
    }

    public func compareRepair(finding: DoctorFinding) throws -> RepairComparison {
        guard finding.code == .localDataDetected, finding.name.hasSuffix(".app") else {
            throw MacBayError.unsupportedOperation("This finding does not describe duplicate applications.")
        }
        let comparison = try service.compareApp(appName: finding.name, volumePath: recoveryVolume(finding: finding))
        guard comparison.localCopy.path == finding.paths[0], comparison.externalCopy.path == finding.paths[1] else {
            throw MacBayError.unsupportedOperation("Application paths changed. Refresh diagnosis before repairing.")
        }
        return comparison
    }

    public func planRepair(comparison: RepairComparison, action: RepairAction) throws -> RepairPlan {
        let plan = try service.planRepair(appName: comparison.appName, action: action, volumePath: comparison.volumePath)
        guard plan.localURL.path == comparison.localCopy.path, plan.externalURL.path == comparison.externalCopy.path else {
            throw MacBayError.unsupportedOperation("Application paths changed. Refresh diagnosis.")
        }
        return plan
    }

    public func executeRepair(plan: RepairPlan, force: Bool) throws -> RepairExecutionResult {
        // Re-plan immediately before mutation; do not execute a stale confirmation.
        let current = try service.planRepair(appName: plan.appName, action: plan.action, volumePath: plan.volumeURL.path)
        guard current.localURL == plan.localURL, current.externalURL == plan.externalURL,
              current.status == plan.status, current.sizeBytes == plan.sizeBytes,
              current.requiredExternalSpaceBytes == plan.requiredExternalSpaceBytes else {
            throw MacBayError.unsupportedOperation("Repair conditions changed. Review a new preview before retrying.")
        }
        return try service.executeRepair(plan: plan, force: force)
    }

    public func previewRollback(finding: DoctorFinding) throws -> RepairJournalRecord {
        let volume = try recoveryVolume(finding: finding)
        guard finding.code == .incompleteOperation,
              let record = DarwinRepairJournal(fileManager: fileManager).load(appName: finding.name, on: URL(fileURLWithPath: volume)),
              record.localPath == finding.paths[0], record.externalPath == finding.paths[1],
              record.volumePath == volume, record.phase != .completed else {
            throw MacBayError.unsupportedOperation("No matching interrupted repair journal. Follow this finding's guidance; adoption recovery is a separate operation.")
        }
        return record
    }

    public func executeRollback(record: RepairJournalRecord) throws -> RepairExecutionResult {
        guard DarwinRepairJournal(fileManager: fileManager).load(appName: record.appName, on: URL(fileURLWithPath: record.volumePath)) == record else {
            throw MacBayError.unsupportedOperation("Repair journal changed. Refresh diagnosis before rollback.")
        }
        guard try eligibleVolumes().contains(where: { $0.path == record.volumePath }) else {
            throw MacBayError.invalidVolume("Reconnect the repair volume before rollback.")
        }
        let inspector = ProcessInspector(fileManager: fileManager)
        for path in [record.localPath, record.externalPath, record.backupPath, record.localBackupPath, record.stagingPath] {
            if fileManager.fileExists(atPath: path) {
                try inspector.assertSafeToMove(path: URL(fileURLWithPath: path))
            }
        }
        return try service.rollbackRepair(appName: record.appName, volumePath: record.volumePath)
    }

    public func loadStatus() throws -> StatusReport {
        try service.status()
    }

    public func loadScan() throws -> ScanReport {
        if let applicationDirectories {
            return service.scan(applicationDirectories: applicationDirectories)
        } else {
            return service.scan()
        }
    }

    public func loadDoctor(volumePath: String?) throws -> DoctorReport {
        try service.doctor(volumePath: volumePath)
    }

    public func eligibleVolumes() throws -> [StorageVolume] {
        try volumeManager.externalVolumes()
    }

    public func defaultVolume() throws -> DefaultVolume? {
        try configStore.load().defaultVolume
    }

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        try service.dock(
            appName: appName,
            volumePath: volumePath,
            dryRun: dryRun,
            force: force,
            progress: progress
        )
    }

    public func undock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        try service.undock(
            appName: appName,
            volumePath: volumePath,
            dryRun: dryRun,
            progress: progress
        )
    }

    public func volumePath(containing path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.volume else {
            return nil
        }
        return volumeURL.standardizedFileURL.path
    }

    public func planAdopt(
        appName: String,
        volumePath: String,
        progress: ProgressHandler?
    ) throws -> AdoptPlan {
        try service.planAdopt(appName: appName, volumePath: volumePath, progress: progress)
    }

    public func executeAdopt(
        plan: AdoptPlan,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> AdoptExecutionResult {
        try service.executeAdopt(plan: plan, force: force, progress: progress)
    }
}
