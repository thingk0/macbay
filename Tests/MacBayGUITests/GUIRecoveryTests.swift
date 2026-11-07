import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIRecoveryTests: XCTestCase {
    private var root: URL!
    private var volume: URL!
    private var status: StatusReport!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        volume = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        status = StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
            externalVolumes: [StorageVolume(name: "Fixture", path: volume.path, isInternal: false, totalBytes: 1000, availableBytes: 900)],
            dockedItems: [])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var reader: GUIRecoveryReader { GUIRecoveryReader(fileManager: .default) }
    private func doctor(_ paths: [String], name: String = "Example.app") -> DoctorReport {
        DoctorReport(generatedAt: "", volumes: [], findings: [
            DoctorFinding(code: .incompleteOperation, status: .needsAttention, category: .applicationLink,
                name: name, paths: paths, detail: "Interrupted fixture", recommendation: "Inspect the original paths.")
        ], summary: DoctorSummary(checked: 1, healthy: 0, unmanaged: 0, needsAttention: 1, unableToVerify: 0), warnings: [])
    }
    private func repair() -> RepairJournalRecord {
        let source = root.appendingPathComponent("Applications/Example.app").path
        let external = MacBayPaths.applicationsRoot(on: volume).appendingPathComponent("Example.app").path
        return RepairJournalRecord(id: "fixture", appName: "Example.app", localPath: source, externalPath: external,
            backupPath: volume.appendingPathComponent("MacBay/Backups/fixture/Example.app").path,
            stagingPath: volume.appendingPathComponent("MacBay/.operations/.staging-fixture/Example.app").path,
            localBackupPath: root.appendingPathComponent("Applications/.Example.app.macbay-local-backup-fixture").path,
            volumePath: volume.path, phase: .staged, timestamp: "",
            originalManifestItem: DockedItem(name: "Example.app", sourcePath: source, externalPath: external,
                                             sizeBytes: 100, kind: .application, dockedAt: ""))
    }
    func testMatchingRepairJournalOffersOnlyRecordedRollback() throws {
        let record = repair()
        try DarwinRepairJournal().save(record, on: volume)
        let items = reader.items(doctor: doctor([record.localPath, record.externalPath]), status: status)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.source, .repair)
        XCTAssertEqual(item.capability, .rollback(record))
        XCTAssertEqual(item.paths.count, 5)
    }
    func testUnsupportedAndDisconnectedFindingsRemainReadOnly() {
        let record = repair()
        let items = reader.items(doctor: doctor([record.localPath, record.externalPath]), status: status)
        XCTAssertNil(items.first?.capability.actionTitle)
        XCTAssertEqual(items.first?.source, .unknown)
        let disconnected = StatusReport(generatedAt: "", internalVolume: status.internalVolume, externalVolumes: [], dockedItems: [])
        let missing = reader.items(doctor: doctor([record.localPath, record.externalPath]), status: disconnected)
        XCTAssertTrue(missing.first?.guidance.contains("Reconnect") == true)
        XCTAssertNil(missing.first?.capability.actionTitle)
    }
    func testAdoptionAndMoveRestoreStatesExposeSafeSpecificCommands() throws {
        let source = root.appendingPathComponent("Applications/Example.app").path
        let external = volume.appendingPathComponent("MacBay/Applications/Example.app").path
        let adoption = AdoptOperationRecord(id: "adopt", appName: "Example.app", sourcePath: source,
            originalExternalPath: volume.appendingPathComponent("Original.app").path, targetExternalPath: external,
            originalLinkTarget: external, volumePath: volume.path, phase: .linkReplaced, timestamp: "")
        let journal = OperationJournal()
        try journal.save(adoption, on: volume)
        let adopt = try XCTUnwrap(reader.items(doctor: doctor([source, external]), status: status).first)
        XCTAssertEqual(adopt.source, .adopt)
        guard case .manual(let adoptCommand) = adopt.capability else { return XCTFail("Expected manual adoption") }
        XCTAssertTrue(adoptCommand?.hasPrefix("mb adopt '") == true)
        XCTAssertTrue(adoptCommand?.hasSuffix("--dry-run") == true)
        journal.remove(for: "Example.app", on: volume)
        for kind in [MoveOperationRecord.Kind.move, .restore] {
            let move = MoveOperationRecord(id: kind.rawValue, kind: kind, name: "Example.app",
                sourcePath: source, destinationPath: external, volumePath: volume.path, phase: .copied, timestamp: "")
            try journal.saveMove(move, on: volume)
            let item = try XCTUnwrap(reader.items(doctor: doctor([source, external]), status: status).first)
            XCTAssertEqual(item.source, kind == .move ? .move : .restore)
            XCTAssertNil(item.capability.actionTitle)
            guard case .manual(let command) = item.capability else { return XCTFail("Expected specific CLI guidance") }
            XCTAssertTrue(command?.hasPrefix(kind == .move ? "mb move " : "mb unmove ") == true)
            journal.removeMove(id: move.id, on: volume)
        }
    }
    func testInterruptedXcodeMoveExposesBackupAndDoctorGuidance() throws {
        let source = root.appendingPathComponent("home/Library/Developer/Xcode/Archives").path
        let destination = MacBayPaths.xcodeArchivesRoot(on: volume).path
        let backup = root.appendingPathComponent("home/Library/Developer/Xcode/.Archives.macbay-backup").path
        let record = MoveOperationRecord(id: "xcode", kind: .move, name: "Archives", sourcePath: source,
            destinationPath: destination, backupPath: backup, volumePath: volume.path, phase: .copied, timestamp: "")
        try OperationJournal().saveMove(record, on: volume)
        let item = try XCTUnwrap(reader.items(doctor: doctor([source, destination], name: "Archives"), status: status).first)
        XCTAssertEqual(item.source, .move)
        XCTAssertTrue(item.paths.contains(backup))
        XCTAssertEqual(item.capability, .manual(command: "mb doctor --volume '" + volume.path + "' --fix --dry-run"))
        XCTAssertTrue(item.guidance.contains("backup may be incomplete"))
    }

    func testAmbiguousJournalsNeverOfferRollback() throws {
        let record = repair()
        try DarwinRepairJournal().save(record, on: volume)
        try OperationJournal().save(AdoptOperationRecord(id: "ambiguous", appName: record.appName,
            sourcePath: record.localPath, originalExternalPath: record.externalPath,
            targetExternalPath: record.externalPath, originalLinkTarget: record.externalPath,
            volumePath: volume.path, phase: .started, timestamp: ""), on: volume)
        let item = try XCTUnwrap(reader.items(doctor: doctor([record.localPath, record.externalPath]), status: status).first)
        XCTAssertEqual(item.source, .unknown)
        XCTAssertNil(item.capability.actionTitle)
    }
    func testUnsupportedRepairSchemaProvidesManualGuidanceOnly() throws {
        let record = repair()
        let unsupported = RepairJournalRecord(schemaVersion: 2, id: record.id, appName: record.appName,
            localPath: record.localPath, externalPath: record.externalPath, backupPath: record.backupPath,
            stagingPath: record.stagingPath, localBackupPath: record.localBackupPath, volumePath: record.volumePath,
            phase: record.phase, timestamp: record.timestamp, originalManifestItem: record.originalManifestItem)
        try DarwinRepairJournal().save(unsupported, on: volume)
        let item = try XCTUnwrap(reader.items(doctor: doctor([record.localPath, record.externalPath]), status: status).first)
        XCTAssertEqual(item.source, .unknown)
        XCTAssertNil(item.capability.actionTitle)
    }
    func testUpdateRecoveryUsesTheSameTypedUpdateActionAndRecordedDestination() throws {
        var preparing = GUIExamples.updates[0]
        preparing.phase = .preparing
        let awaiting = GUIExamples.updates[0]
        let items = reader.updateItems([preparing, awaiting])
        XCTAssertEqual(items[0].capability, .update(GUIUpdateRequest(action: .begin,
            appPath: preparing.sourcePath, expectedRecord: preparing)))
        XCTAssertEqual(items[1].capability, .update(GUIUpdateRequest(action: .finish,
            appPath: awaiting.sourcePath, expectedRecord: awaiting)))
    }

    @MainActor
    func testRecoveryPreviewAndCancelNeverExecuteAndDemoRollbackRefreshes() async throws {
        let service = DemoGUIService()
        let store = GUIStore(service: service, isDemo: true, monitorVolumes: false)
        await store.refresh()
        let item = try XCTUnwrap(store.recoverySnapshot?.items.first { $0.source == .repair })
        await store.previewRecovery(item)
        let cancelled = try XCTUnwrap(store.actionPreview)
        store.dismissAction()
        await store.confirmAction(GUIActionConfirmation(previewID: cancelled.id, reviewed: true))
        let unchanged = await service.recovery()
        XCTAssertTrue(unchanged.items.contains { $0.id == item.id })
        await store.previewRecovery(item)
        let preview = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        XCTAssertTrue(try XCTUnwrap(store.actionResult).succeeded)
        XCTAssertFalse(store.recoverySnapshot?.items.contains { $0.id == item.id } == true)
    }

    @MainActor
    func testReadOnlyRecoveryGuidanceCannotOpenExecutionSheet() async throws {
        let service = DemoGUIService()
        let store = GUIStore(service: service, isDemo: true, monitorVolumes: false)
        await store.refresh()
        let item = try XCTUnwrap(store.recoverySnapshot?.items.first { $0.source == .adopt })
        await store.previewRecovery(item)
        XCTAssertNil(store.actionPreview)
        XCTAssertNil(store.actionResult)
    }
}
