import XCTest
@testable import MacBayKit

final class RepairAppUseCaseTests: XCTestCase {
    private var safetyInspector: MockRepairSafetyInspector!
    private var bundleOperations: MockRepairBundleOperations!
    private var manifestRepository: MockRepairManifestRepository!
    private var journal: MockRepairJournal!
    private var volumeInspector: MockRepairVolumeInspector!
    private var systemRefresher: MockSystemEnvironmentRefresher!
    private var useCase: RepairAppUseCase!

    private let volumeURL = URL(fileURLWithPath: "/Volumes/ExternalSSD")
    private let localURL = URL(fileURLWithPath: "/Applications/Kiro CLI.app")
    private let externalURL = URL(fileURLWithPath: "/Volumes/ExternalSSD/MacBay/Applications/Kiro CLI.app")

    override func setUp() {
        super.setUp()
        safetyInspector = MockRepairSafetyInspector()
        bundleOperations = MockRepairBundleOperations()
        manifestRepository = MockRepairManifestRepository()
        journal = MockRepairJournal()
        volumeInspector = MockRepairVolumeInspector()
        systemRefresher = MockSystemEnvironmentRefresher()

        useCase = RepairAppUseCase(
            safetyInspector: safetyInspector,
            bundleOperations: bundleOperations,
            manifestRepository: manifestRepository,
            journal: journal,
            volumeInspector: volumeInspector,
            systemRefresher: systemRefresher,
            operationLock: NoOpVolumeOperationLock()
        )

        // Setup base valid state
        bundleOperations.existingFiles.insert(localURL.path)
        bundleOperations.existingFiles.insert(externalURL.path)

        manifestRepository.items["Kiro CLI.app"] = DockedItem(
            name: "Kiro CLI.app",
            sourcePath: localURL.path,
            externalPath: externalURL.path,
            sizeBytes: 100_000_000,
            kind: .application,
            dockedAt: "2026-09-01T00:00:00Z"
        )

        safetyInspector.bundleInfos[localURL.path] = AppCopyInfo(
            path: localURL.path,
            bundleIdentifier: "com.kiro.cli",
            version: "1.2.0",
            buildNumber: "120",
            sizeBytes: 100_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "Safe"
        )

        safetyInspector.bundleInfos[externalURL.path] = AppCopyInfo(
            path: externalURL.path,
            bundleIdentifier: "com.kiro.cli",
            version: "1.1.0",
            buildNumber: "110",
            sizeBytes: 95_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "Safe"
        )

        volumeInspector.availableBytesMap[volumeURL.path] = 10_000_000_000
        volumeInspector.writableMap[volumeURL.path] = true
    }

    func testCompareValidIdenticalIdentifiersCanRedock() throws {
        let comparison = try useCase.compare(appName: "Kiro CLI.app", on: volumeURL)

        XCTAssertEqual(comparison.appName, "Kiro CLI.app")
        XCTAssertTrue(comparison.canRedock)
        XCTAssertTrue(comparison.redockBlockers.isEmpty)
        XCTAssertEqual(comparison.suggestedActions, [.redock, .keepLocal])
        XCTAssertEqual(comparison.localCopy.version, "1.2.0")
        XCTAssertEqual(comparison.externalCopy.version, "1.1.0")
    }

    func testCompareBundleIdentifierMismatchBlocksRedock() throws {
        safetyInspector.bundleInfos[localURL.path] = AppCopyInfo(
            path: localURL.path,
            bundleIdentifier: "com.other.app",
            version: "2.0.0",
            buildNumber: "200",
            sizeBytes: 100_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "Safe"
        )

        let comparison = try useCase.compare(appName: "Kiro CLI.app", on: volumeURL)

        XCTAssertFalse(comparison.canRedock)
        XCTAssertTrue(comparison.redockBlockers.contains { $0.contains("Bundle identifier mismatch") })
        XCTAssertEqual(comparison.suggestedActions, [.keepLocal])
    }

    func testCompareBlockedLocalAppRefusesRedock() throws {
        safetyInspector.bundleInfos[localURL.path] = AppCopyInfo(
            path: localURL.path,
            bundleIdentifier: "com.kiro.cli",
            version: "1.2.0",
            buildNumber: "120",
            sizeBytes: 100_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "Blocked",
            compatibilityReasons: ["Kernel extension detected"]
        )

        let comparison = try useCase.compare(appName: "Kiro CLI.app", on: volumeURL)

        XCTAssertFalse(comparison.canRedock)
        XCTAssertTrue(comparison.redockBlockers.contains { $0.contains("compatibility is Blocked") })
    }

    func testPlanKeepLocalReturnsReadyWithZeroRequiredSpace() throws {
        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .keepLocal, on: volumeURL)

        XCTAssertEqual(plan.action, .keepLocal)
        XCTAssertEqual(plan.status, .ready)
        XCTAssertEqual(plan.requiredExternalSpaceBytes, 0)
        XCTAssertEqual(plan.estimatedFreedInternalBytes, 0)
    }

    func testPlanRedockInsufficientSpaceThrows() throws {
        volumeInspector.availableBytesMap[volumeURL.path] = 1_000 // Very low space

        XCTAssertThrowsError(try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)) { error in
            guard case let MacBayError.insufficientSpace(path, needed, avail) = error else {
                return XCTFail("Expected insufficientSpace error but got \(error)")
            }
            XCTAssertEqual(path, volumeURL.path)
            XCTAssertGreaterThan(needed, avail)
        }
    }

    func testPlanRedockPopupRiskRequiresReview() throws {
        safetyInspector.bundleInfos[localURL.path] = AppCopyInfo(
            path: localURL.path,
            bundleIdentifier: "com.kiro.cli",
            version: "1.2.0",
            buildNumber: "120",
            sizeBytes: 100_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "PopupRisk",
            compatibilityReasons: ["SMPrivilegedExecutables helper tool"]
        )

        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)

        if case let .reviewRequired(reasons, _) = plan.status {
            XCTAssertTrue(reasons.contains("SMPrivilegedExecutables helper tool"))
        } else {
            XCTFail("Expected .reviewRequired but got \(plan.status)")
        }
    }

    func testExecuteKeepLocalRemovesManifestItemAndPreservesFiles() throws {
        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .keepLocal, on: volumeURL)
        let result = try useCase.execute(plan: plan, force: false)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.action, .keepLocal)
        XCTAssertNil(manifestRepository.items["Kiro CLI.app"])
        XCTAssertTrue(bundleOperations.existingFiles.contains(localURL.path))
        XCTAssertTrue(bundleOperations.existingFiles.contains(externalURL.path))
    }

    func testExecuteRedockCopiesStagedBacksUpExternalAndUpdatesSymlink() throws {
        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)
        let result = try useCase.execute(plan: plan, force: false)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.action, .redock)
        XCTAssertNotNil(result.backupPath)
        XCTAssertTrue(bundleOperations.copies.count >= 1)
        XCTAssertTrue(bundleOperations.createdSymlinks.contains { $0.symlink == localURL.path && $0.target == externalURL.path })
        XCTAssertNotNil(manifestRepository.items["Kiro CLI.app"])
        XCTAssertNil(journal.journal["Kiro CLI.app"]) // Cleaned up
        XCTAssertTrue(systemRefresher.refreshedBundles.contains(localURL))
    }

    func testExecuteRedockReviewRequiresForce() throws {
        safetyInspector.bundleInfos[localURL.path] = AppCopyInfo(
            path: localURL.path,
            bundleIdentifier: "com.kiro.cli",
            version: "1.2.0",
            buildNumber: "120",
            sizeBytes: 100_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "PopupRisk",
            compatibilityReasons: ["Helper tools"]
        )

        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)

        // Without force -> throws forceRequired
        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false)) { error in
            guard case MacBayError.forceRequired = error else {
                return XCTFail("Expected forceRequired error but got \(error)")
            }
        }

        // With force -> succeeds
        let result = try useCase.execute(plan: plan, force: true)
        XCTAssertEqual(result.outcome, .completed)
    }

    func testExecuteRedockFailureAtManifestRollsBackEverything() throws {
        manifestRepository.failOnRecord = true

        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)

        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false))

        // Check that rollback restored local app, restored external backup, and removed symlink
        XCTAssertTrue(bundleOperations.existingFiles.contains(localURL.path))
        XCTAssertTrue(bundleOperations.existingFiles.contains(externalURL.path))
    }

    func testRollbackFromInterruptedJournalRestoresOriginalCopies() throws {
        let backupURL = volumeURL.appendingPathComponent("MacBay/Backups/op-123/Kiro CLI.app")
        let stagingURL = volumeURL.appendingPathComponent("MacBay/.operations/.staging-op-123/Kiro CLI.app")
        let localBackupURL = URL(fileURLWithPath: "/Applications/.Kiro CLI.app.macbay-local-backup-op-123")

        bundleOperations.existingFiles.insert(backupURL.path)
        bundleOperations.existingFiles.insert(localBackupURL.path)
        bundleOperations.existingFiles.insert(localURL.path)
        bundleOperations.symlinks.insert(localURL.path)

        let originalItem = DockedItem(
            name: "Kiro CLI.app",
            sourcePath: localURL.path,
            externalPath: externalURL.path,
            sizeBytes: 100_000_000,
            kind: .application,
            dockedAt: "2026-09-01T00:00:00Z"
        )

        journal.journal["Kiro CLI.app"] = RepairJournalRecord(
            id: "op-123",
            appName: "Kiro CLI.app",
            localPath: localURL.path,
            externalPath: externalURL.path,
            backupPath: backupURL.path,
            stagingPath: stagingURL.path,
            localBackupPath: localBackupURL.path,
            volumePath: volumeURL.path,
            phase: .linked,
            timestamp: "2026-09-11T12:00:00Z",
            originalManifestItem: originalItem
        )

        let result = try useCase.rollback(appName: "Kiro CLI.app", on: volumeURL)

        if case let .noChanges(reason) = result.outcome {
            XCTAssertTrue(reason.contains("Rollback completed"))
        } else {
            XCTFail("Expected noChanges outcome for rollback")
        }

        XCTAssertNil(journal.journal["Kiro CLI.app"])
    }

    func testExecuteThrowsOperationInProgressWhenPendingJournalExists() throws {
        let plan = try useCase.plan(appName: "Kiro CLI.app", action: .redock, on: volumeURL)
        let originalItem = DockedItem(
            name: "Kiro CLI.app",
            sourcePath: localURL.path,
            externalPath: externalURL.path,
            sizeBytes: 100_000_000,
            kind: .application,
            dockedAt: "2026-09-01T00:00:00Z"
        )
        journal.journal["Kiro CLI.app"] = RepairJournalRecord(
            id: "op-pending",
            appName: "Kiro CLI.app",
            localPath: localURL.path,
            externalPath: externalURL.path,
            backupPath: "/tmp/backup",
            stagingPath: "/tmp/staging",
            localBackupPath: "/tmp/localBackup",
            volumePath: volumeURL.path,
            phase: .started,
            timestamp: "2026-09-01T00:00:00Z",
            originalManifestItem: originalItem
        )

        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false)) { error in
            guard case let MacBayError.operationInProgress(path, details) = error else {
                return XCTFail("Expected operationInProgress but got \(error)")
            }
            XCTAssertEqual(path, volumeURL.path)
            XCTAssertTrue(details.contains("mb repair \"Kiro CLI.app\" --rollback"))
        }
    }
}

// MARK: - Mocks

private final class MockRepairSafetyInspector: RepairSafetyInspector, @unchecked Sendable {
    var bundleInfos: [String: AppCopyInfo] = [:]
    var compatibility: CompatibilityAssessment = CompatibilityAssessment(grade: .safe, reasons: [], evidence: [])
    var processesRunning = false

    func inspectBundle(at url: URL) throws -> AppCopyInfo {
        if let info = bundleInfos[url.path] {
            return info
        }
        return AppCopyInfo(
            path: url.path,
            bundleIdentifier: "com.mock.app",
            version: "1.0",
            buildNumber: "1",
            sizeBytes: 50_000_000,
            signatureStatus: "Valid",
            compatibilityGrade: "Safe"
        )
    }

    func assertSafeToOperate(at urls: [URL]) throws {
        if processesRunning {
            let lock = ProcessLock(process: "test", pid: 999, user: "user", fileDescriptor: "txt", path: urls.first?.path ?? "")
            throw MacBayError.activeProcesses(path: urls.first?.path ?? "", locks: [lock])
        }
    }

    func assessCompatibility(at url: URL) -> CompatibilityAssessment {
        compatibility
    }
}

private final class MockRepairBundleOperations: RepairBundleOperations, @unchecked Sendable {
    var existingFiles: Set<String> = []
    var symlinks: Set<String> = []
    var copies: [(from: String, to: String)] = []
    var moves: [(from: String, to: String)] = []
    var createdSymlinks: [(symlink: String, target: String)] = []

    func fileExists(at url: URL) -> Bool {
        existingFiles.contains(url.path)
    }

    func isSymbolicLink(at url: URL) -> Bool {
        symlinks.contains(url.path)
    }

    func calculateSizeBytes(at url: URL) throws -> UInt64 {
        100_000_000
    }

    func copyBundle(from source: URL, to destination: URL) throws {
        copies.append((source.path, destination.path))
        existingFiles.insert(destination.path)
    }

    func moveBundle(from source: URL, to destination: URL) throws {
        moves.append((source.path, destination.path))
        existingFiles.remove(source.path)
        existingFiles.insert(destination.path)
    }

    func remove(at url: URL) throws {
        existingFiles.remove(url.path)
        symlinks.remove(url.path)
    }

    func createSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws {
        createdSymlinks.append((symlinkURL.path, targetURL.path))
        existingFiles.insert(symlinkURL.path)
        symlinks.insert(symlinkURL.path)
    }
}

private final class MockRepairManifestRepository: RepairManifestRepository, @unchecked Sendable {
    var items: [String: DockedItem] = [:]
    var failOnRecord = false

    func findItem(named appName: String, on volume: URL) throws -> DockedItem? {
        items[appName]
    }

    func removeItem(named appName: String, on volume: URL) throws {
        items.removeValue(forKey: appName)
    }

    func recordItem(_ item: DockedItem, on volume: URL) throws {
        if failOnRecord {
            throw MacBayError.manifestFailed(path: volume.path, details: "Injected manifest write error")
        }
        items[item.name] = item
    }
}

private final class MockRepairJournal: RepairJournaling, @unchecked Sendable {
    var journal: [String: RepairJournalRecord] = [:]

    func save(_ record: RepairJournalRecord, on volume: URL) throws {
        journal[record.appName] = record
    }

    func load(appName: String, on volume: URL) -> RepairJournalRecord? {
        journal[appName]
    }

    func remove(appName: String, on volume: URL) {
        journal.removeValue(forKey: appName)
    }

    func listIncomplete(on volume: URL) -> [RepairJournalRecord] {
        Array(journal.values.filter { $0.phase != .completed })
    }
}

private final class MockRepairVolumeInspector: RepairVolumeInspector, @unchecked Sendable {
    var availableBytesMap: [String: UInt64] = [:]
    var writableMap: [String: Bool] = [:]

    func availableBytes(on volume: URL) throws -> UInt64 {
        availableBytesMap[volume.path] ?? 10_000_000_000
    }

    func isWritable(volume: URL) -> Bool {
        writableMap[volume.path] ?? true
    }
}
