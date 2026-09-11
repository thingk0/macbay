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

    public var shouldThrowStatus: Error?
    public var shouldThrowScan: Error?
    public var shouldThrowDoctor: Error?
    public var shouldThrowDock: Error?
    public var shouldThrowUndock: Error?
    public var shouldThrowDockOnMutate: Error?
    public var shouldThrowUndockOnMutate: Error?

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
}
