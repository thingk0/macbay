import Foundation
import MacBayKit
@testable import MacBayTUI

public final class FakeTUIService: @unchecked Sendable, TUIServiceProtocol {
    public var statusToReturn: StatusReport
    public var scanToReturn: ScanReport
    public var doctorToReturn: DoctorReport
    public var eligibleVolumesToReturn: [StorageVolume]
    public var defaultVolumeToReturn: DefaultVolume?

    public var statusCalls = 0
    public var scanCalls = 0
    public var doctorCalls = 0
    public var dockCalls: [(appName: String, volumePath: String?, dryRun: Bool, force: Bool)] = []
    public var undockCalls: [(appName: String, volumePath: String?, dryRun: Bool)] = []
    public var adoptPlanCalls: [(appName: String, volumePath: String)] = []
    public var adoptExecuteCalls: [(appName: String, force: Bool)] = []

    public var shouldThrowStatus: Error?
    public var shouldThrowScan: Error?
    public var shouldThrowDoctor: Error?
    public var shouldThrowDock: Error?
    public var shouldThrowUndock: Error?
    public var shouldThrowDockOnMutate: Error?
    public var shouldThrowUndockOnMutate: Error?
    public var shouldThrowPlanAdopt: Error?
    public var shouldThrowExecuteAdopt: Error?

    public var adoptPlanToReturn: AdoptPlan?
    public var adoptResultToReturn: AdoptExecutionResult?

    /// Mount points the fake reports for `volumePath(containing:)`; the longest match wins.
    public var mountedVolumePaths: [String] = []

    /// Simulates slow storage/service calls so tests can observe in-flight request handling.
    public var artificialDelay: TimeInterval = 0

    public init(
        status: StatusReport? = nil,
        scan: ScanReport? = nil,
        doctor: DoctorReport? = nil,
        eligibleVolumes: [StorageVolume] = [],
        defaultVolume: DefaultVolume? = nil
    ) {
        let dummyInternal = StorageVolume(
            name: "Macintosh HD",
            path: "/",
            isInternal: true,
            totalBytes: 500_000_000_000,
            availableBytes: 250_000_000_000
        )
        self.statusToReturn = status ?? StatusReport(
            generatedAt: macBayTimestamp(),
            internalVolume: dummyInternal,
            externalVolumes: eligibleVolumes,
            defaultVolume: defaultVolume.map { StatusDefaultVolume(name: $0.name, path: $0.path) },
            dockedItems: []
        )
        self.scanToReturn = scan ?? ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100_000_000,
            candidates: [],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        self.doctorToReturn = doctor ?? DoctorReport(
            generatedAt: macBayTimestamp(),
            volumes: [],
            findings: [],
            summary: DoctorSummary(checked: 0, healthy: 0, unmanaged: 0, needsAttention: 0, unableToVerify: 0),
            warnings: []
        )
        self.eligibleVolumesToReturn = eligibleVolumes
        self.defaultVolumeToReturn = defaultVolume
    }

    var repairComparison: RepairComparison?
    var repairPlan: RepairPlan?
    var rollbackRecord: RepairJournalRecord?
    var repairError: Error?
    var repairExecutions: [(RepairPlan, Bool)] = []
    var rollbackExecutions = 0

    public func compareRepair(finding: DoctorFinding) throws -> RepairComparison {
        simulateWorkload()
        guard let value = repairComparison else { throw MacBayError.unsupportedOperation("No comparison") }
        return value
    }
    public func planRepair(comparison: RepairComparison, action: RepairAction) throws -> RepairPlan {
        guard let value = repairPlan else { throw MacBayError.unsupportedOperation("No plan") }
        return value
    }
    public func executeRepair(plan: RepairPlan, force: Bool) throws -> RepairExecutionResult {
        repairExecutions.append((plan, force))
        if let repairError { throw repairError }
        return RepairExecutionResult(action: plan.action, appName: plan.appName, outcome: .completed, localPath: plan.localURL.path, externalPath: plan.externalURL.path)
    }
    public func previewRollback(finding: DoctorFinding) throws -> RepairJournalRecord {
        guard let value = rollbackRecord else { throw MacBayError.unsupportedOperation("No repair journal") }
        return value
    }
    public func executeRollback(record: RepairJournalRecord) throws -> RepairExecutionResult {
        rollbackExecutions += 1
        return RepairExecutionResult(action: .redock, appName: record.appName, outcome: .completed, localPath: record.localPath, externalPath: record.externalPath)
    }

    private func simulateWorkload() {
        if artificialDelay > 0 {
            Thread.sleep(forTimeInterval: artificialDelay)
        }
    }

    public func loadStatus() throws -> StatusReport {
        statusCalls += 1
        simulateWorkload()
        if let err = shouldThrowStatus {
            throw err
        }
        return statusToReturn
    }

    public func loadScan() throws -> ScanReport {
        scanCalls += 1
        simulateWorkload()
        if let err = shouldThrowScan {
            throw err
        }
        return scanToReturn
    }

    public func loadDoctor(volumePath: String?) throws -> DoctorReport {
        doctorCalls += 1
        simulateWorkload()
        if let err = shouldThrowDoctor {
            throw err
        }
        return doctorToReturn
    }

    public func eligibleVolumes() throws -> [StorageVolume] {
        eligibleVolumesToReturn
    }

    public func defaultVolume() throws -> DefaultVolume? {
        defaultVolumeToReturn
    }

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        dockCalls.append((appName, volumePath, dryRun, force))
        simulateWorkload()
        if let err = shouldThrowDock {
            throw err
        }
        if !dryRun, let err = shouldThrowDockOnMutate {
            throw err
        }
        progress?(.validating)
        progress?(.copying)
        progress?(.updatingLink)
        return MigrationResult(
            operation: "dock",
            name: appName,
            sourcePath: "/Applications/\(appName)",
            destinationPath: "\(volumePath ?? "/Volumes/External")/MacBay/Applications/\(appName)",
            sizeBytes: 1_000_000_000,
            dryRun: dryRun,
            messages: [
                "Destination available: 50 GB",
                "Estimated internal space freed: 1 GB"
            ]
        )
    }

    public func undock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        undockCalls.append((appName, volumePath, dryRun))
        simulateWorkload()
        if let err = shouldThrowUndock {
            throw err
        }
        if !dryRun, let err = shouldThrowUndockOnMutate {
            throw err
        }
        progress?(.validating)
        progress?(.copying)
        progress?(.updatingLink)
        return MigrationResult(
            operation: "undock",
            name: appName,
            sourcePath: "\(volumePath ?? "/Volumes/External")/MacBay/Applications/\(appName)",
            destinationPath: "/Applications/\(appName)",
            sizeBytes: 1_000_000_000,
            dryRun: dryRun,
            messages: [
                "Internal space required: 1 GB",
                "Internal space available: 200 GB"
            ]
        )
    }

    public func volumePath(containing path: String) -> String? {
        mountedVolumePaths
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    public func planAdopt(
        appName: String,
        volumePath: String,
        progress: ProgressHandler?
    ) throws -> AdoptPlan {
        adoptPlanCalls.append((appName, volumePath))
        simulateWorkload()
        if let err = shouldThrowPlanAdopt {
            throw err
        }
        progress?(.validating)
        progress?(.inspectingStorage)
        return adoptPlanToReturn ?? FakeTUIService.makeAdoptPlan(appName: appName, volumePath: volumePath)
    }

    public func executeAdopt(
        plan: AdoptPlan,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> AdoptExecutionResult {
        adoptExecuteCalls.append((plan.appName, force))
        simulateWorkload()
        if let err = shouldThrowExecuteAdopt {
            throw err
        }
        if let result = adoptResultToReturn {
            return result
        }
        progress?(.savingManifest)
        progress?(.moving)
        progress?(.updatingLink)
        return AdoptExecutionResult(
            outcome: .completed,
            appName: plan.appName,
            sourcePath: plan.targetURL.path,
            destinationPath: plan.destinationURL.path,
            symlinkPath: plan.symlinkURL.path,
            sizeBytes: plan.sizeBytes,
            mode: plan.mode,
            rollback: .notRequired
        )
    }

    public static func makeAdoptPlan(
        appName: String = "UnmanagedApp.app",
        volumePath: String = "/Volumes/KLEVV",
        status: AdoptPlanStatus = .ready,
        mode: AdoptMode = .moveAndAdopt,
        sizeBytes: UInt64 = 1_000_000_000,
        targetPath: String? = nil,
        destinationPath: String? = nil
    ) -> AdoptPlan {
        let volume = URL(fileURLWithPath: volumePath)
        let source = URL(fileURLWithPath: "/Applications/\(appName)")
        let destination = URL(fileURLWithPath: destinationPath ?? volume.appendingPathComponent("MacBay/Applications/\(appName)").path)

        let compatibility: CompatibilityAssessment
        switch status {
        case .blocked:
            compatibility = CompatibilityAssessment(
                grade: .blocked,
                reasons: ["Hypervisor entitlement present"],
                evidence: ["com.apple.security.hypervisor"]
            )
        case let .reviewRequired(reasons, evidence):
            compatibility = CompatibilityAssessment(grade: .popupRisk, reasons: reasons, evidence: evidence)
        default:
            compatibility = CompatibilityAssessment(grade: .safe)
        }

        return AdoptPlan(
            appName: appName,
            sourceURL: source,
            targetURL: URL(fileURLWithPath: targetPath ?? volume.appendingPathComponent(appName).path),
            destinationURL: destination,
            symlinkURL: source,
            volumeURL: volume,
            mode: mode,
            status: status,
            sizeBytes: sizeBytes,
            compatibility: compatibility,
            steps: []
        )
    }
}
