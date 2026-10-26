import Foundation
import XCTest
@testable import MacBayKit

final class RepairBackupServiceTests: XCTestCase {
    private var tempDir: URL!
    private var configHome: URL!
    private var externalSSD: VolumeDiskInfo!
    private var internalVolume: VolumeDiskInfo!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayRepairBackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        configHome = tempDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)

        internalVolume = VolumeDiskInfo(
            mountPoint: "/",
            isInternal: true,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "Apple Fabric",
            volumeName: "Macintosh HD",
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000,
            volumeUUID: "UUID-INTERNAL"
        )
        externalSSD = VolumeDiskInfo(
            mountPoint: "/Volumes/ExternalSSD",
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: "ExternalSSD",
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000,
            volumeUUID: "UUID-SSD"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService(fake: FakeRepairBackupUseCase) -> MacBayService {
        let mounted = ["/", "/Volumes/ExternalSSD"]
        let volumeManager = VolumeManager(
            fileManager: MockFileManager(mountedPaths: mounted),
            diskInfoProvider: MockDiskInfoProvider([
                "/": internalVolume,
                "/Volumes/ExternalSSD": externalSSD
            ])
        )
        let configStore = ConfigStore(
            environment: ["XDG_CONFIG_HOME": configHome.path],
            homeDirectory: tempDir
        )
        let historyStore = HistoryStore(
            environment: ["XDG_STATE_HOME": tempDir.appendingPathComponent("state").path],
            homeDirectory: tempDir
        )
        return MacBayService(
            fileManager: MockFileManager(mountedPaths: mounted),
            volumeManager: volumeManager,
            configStore: configStore,
            repairBackupUseCase: fake,
            historyStore: historyStore
        )
    }

    private func makeEntry(id: String = "id-1", appName: String = "Kiro CLI.app") -> RepairBackupEntry {
        RepairBackupEntry(
            id: id,
            appName: appName,
            path: "/Volumes/ExternalSSD/MacBay/Backups/\(id)/\(appName)",
            version: "1.1.0",
            buildNumber: "110",
            savedAt: "2026-10-12T10:55:00Z",
            sizeBytes: 1_000,
            state: .unreferenced
        )
    }

    private func makeInventory(entries: [RepairBackupEntry]) -> RepairBackupInventory {
        RepairBackupInventory(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            backupsRoot: "/Volumes/ExternalSSD/MacBay/Backups",
            backups: entries,
            summary: RepairBackupSummary(
                count: entries.count,
                totalSizeBytes: 1_000,
                referencedCount: 0,
                unverifiableCount: 0
            ),
            notes: [],
            warnings: []
        )
    }

    private func makePlan(entry: RepairBackupEntry) -> RepairBackupRemovalPlan {
        RepairBackupRemovalPlan(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            requestedIDs: [entry.id],
            selected: [entry],
            refused: [],
            totalBytes: 1_000,
            notes: []
        )
    }

    private func makeResult(entry: RepairBackupEntry, failed: Bool = false) -> RepairBackupRemovalResult {
        RepairBackupRemovalResult(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            removed: failed ? [] : [entry],
            refused: [],
            failed: failed
                ? [RepairBackupRemovalFailure(id: entry.id, appName: entry.appName, path: entry.path, reason: "simulated")]
                : [],
            reclaimedBytes: failed ? 0 : 1_000,
            freeBytesBefore: 100,
            freeBytesAfter: 1_100,
            notes: []
        )
    }

    func testListUsesSelectedVolumeAndDoesNotRecordHistory() throws {
        let fake = FakeRepairBackupUseCase()
        let entry = makeEntry()
        fake.inventoryResult = makeInventory(entries: [entry])
        let service = makeService(fake: fake)

        let inventory = try service.listRepairBackups(volumePath: nil)

        XCTAssertEqual(fake.receivedVolumeName, "ExternalSSD")
        XCTAssertEqual(inventory.backups.map(\.id), [entry.id])
        XCTAssertTrue(service.history().isEmpty)
    }

    func testPlanUsesSelectedVolumeAndDoesNotRecordHistory() throws {
        let fake = FakeRepairBackupUseCase()
        let entry = makeEntry()
        fake.planResult = makePlan(entry: entry)
        let service = makeService(fake: fake)

        let plan = try service.planRepairBackupRemoval(ids: [entry.id], volumePath: nil)

        XCTAssertEqual(fake.receivedIDs, [entry.id])
        XCTAssertEqual(plan.selected.map(\.id), [entry.id])
        XCTAssertTrue(service.history().isEmpty)
    }

    func testExecuteRecordsSuccessInHistory() throws {
        let fake = FakeRepairBackupUseCase()
        let entry = makeEntry()
        fake.planResult = makePlan(entry: entry)
        fake.executeResult = makeResult(entry: entry)
        let service = makeService(fake: fake)
        let plan = try service.planRepairBackupRemoval(ids: [entry.id], volumePath: nil)

        let result = try service.executeRepairBackupRemoval(plan: plan)

        XCTAssertEqual(result.exitCode, 0)
        let entries = service.history()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.command, "backups --remove")
        XCTAssertEqual(entries.first?.subject, entry.appName)
        XCTAssertEqual(entries.first?.outcome, .success)
        XCTAssertTrue(entries.first?.detail?.contains("reclaimed") == true)
    }

    func testExecuteRecordsFailureWhenNothingWasRemoved() throws {
        let fake = FakeRepairBackupUseCase()
        let entry = makeEntry()
        fake.executeResult = makeResult(entry: entry, failed: true)
        let service = makeService(fake: fake)
        let plan = makePlan(entry: entry)

        let result = try service.executeRepairBackupRemoval(plan: plan)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(service.history().first?.outcome, .failure)
    }

    func testExecuteRecordsFailureAndRethrows() throws {
        let fake = FakeRepairBackupUseCase()
        let entry = makeEntry()
        fake.executeError = NSError(
            domain: "RepairBackupServiceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated removal error"]
        )
        let service = makeService(fake: fake)
        let plan = makePlan(entry: entry)

        XCTAssertThrowsError(try service.executeRepairBackupRemoval(plan: plan)) { error in
            XCTAssertEqual(error.localizedDescription, "simulated removal error")
        }

        let history = service.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .failure)
        XCTAssertTrue(history.first?.detail?.contains("simulated removal error") == true)
    }
}

private final class FakeRepairBackupUseCase: RepairBackupUseCaseProtocol, @unchecked Sendable {
    var inventoryResult = RepairBackupInventory(
        generatedAt: "2026-10-12T10:55:00Z",
        volumeName: "ExternalSSD",
        volumePath: "/Volumes/ExternalSSD",
        backupsRoot: "/Volumes/ExternalSSD/MacBay/Backups",
        backups: [],
        summary: RepairBackupSummary(count: 0, totalSizeBytes: 0, referencedCount: 0, unverifiableCount: 0),
        notes: [],
        warnings: []
    )
    var planResult = RepairBackupRemovalPlan(
        generatedAt: "2026-10-12T10:55:00Z",
        volumeName: "ExternalSSD",
        volumePath: "/Volumes/ExternalSSD",
        requestedIDs: [],
        selected: [],
        refused: [],
        totalBytes: 0,
        notes: []
    )
    var executeResult = RepairBackupRemovalResult(
        generatedAt: "2026-10-12T10:55:00Z",
        volumeName: "ExternalSSD",
        volumePath: "/Volumes/ExternalSSD",
        removed: [],
        refused: [],
        failed: [],
        reclaimedBytes: 0,
        freeBytesBefore: nil,
        freeBytesAfter: nil,
        notes: []
    )
    var executeError: Error?
    private(set) var receivedIDs: [String] = []
    private(set) var receivedVolumeName: String?

    func inventory(on volume: URL, volumeName: String) throws -> RepairBackupInventory {
        receivedVolumeName = volumeName
        return inventoryResult
    }

    func planRemoval(ids: [String], on volume: URL, volumeName: String) throws -> RepairBackupRemovalPlan {
        receivedIDs = ids
        receivedVolumeName = volumeName
        return planResult
    }

    func execute(plan: RepairBackupRemovalPlan, progress: ProgressHandler?) throws -> RepairBackupRemovalResult {
        if let executeError {
            throw executeError
        }
        return executeResult
    }
}
