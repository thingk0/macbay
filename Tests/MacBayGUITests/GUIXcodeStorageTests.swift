import Foundation
import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIXcodeStorageTests: XCTestCase {
    func testDefaultSelectionMovesOnlyDeviceSupportAndArchives() {
        let selection = GUIXcodeSelection()
        XCTAssertTrue(selection.hasActions)
        XCTAssertTrue(selection.options.externalizeDeviceSupport)
        XCTAssertTrue(selection.options.externalizeArchives)
        XCTAssertFalse(selection.options.externalizeDerivedData)
        XCTAssertFalse(selection.options.cleanDerivedData)
        XCTAssertFalse(selection.options.cleanCaches)
        XCTAssertFalse(selection.options.deleteUnavailableSimulators)
        XCTAssertFalse(selection.options.force)
    }

    func testDerivedDataHasMutuallyExclusiveMoveAndRemoveChoices() {
        var selection = GUIXcodeSelection()
        selection.derivedData = .move
        XCTAssertTrue(selection.options.externalizeDerivedData)
        XCTAssertFalse(selection.options.cleanDerivedData)
        selection.derivedData = .clean
        XCTAssertFalse(selection.options.externalizeDerivedData)
        XCTAssertTrue(selection.options.cleanDerivedData)
        selection.moveDeviceSupport = false
        selection.moveArchives = false
        selection.derivedData = .keep
        XCTAssertFalse(selection.hasActions)
    }

    @MainActor
    func testXcodeWorkflowUsesReviewConfirmationAndInvalidatesChangedSelection() async throws {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        await store.previewXcode()
        let first = try XCTUnwrap(store.actionPreview)
        XCTAssertEqual(first.kind, .xcode)
        XCTAssertNil(store.preview)
        XCTAssertFalse(first.requiresXcodeRemovalConfirmation)
        store.xcodeSelection.cleanCaches = true
        XCTAssertNil(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: first.id, reviewed: true))
        XCTAssertNil(store.actionResult)
        await store.previewXcode()
        let cleanup = try XCTUnwrap(store.actionPreview)
        XCTAssertTrue(cleanup.requiresXcodeRemovalConfirmation)
        await store.confirmAction(GUIActionConfirmation(previewID: cleanup.id, reviewed: true))
        XCTAssertNil(store.actionResult)
        XCTAssertNotNil(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: cleanup.id, reviewed: true, confirmsXcodeRemoval: true))
        XCTAssertTrue(try XCTUnwrap(store.actionResult).succeeded)
        XCTAssertTrue(try XCTUnwrap(store.actionResult).messages.contains { $0.contains("No real developer") })
    }

    func testPreviewWithNoMatchingDataExplainsWhyExecutionIsDisabled() {
        let plan = XcodeStoragePlan(volumePath: "/Volumes/Test", volumeUUID: "TEST", availableBytes: 10_000,
            requiredBytes: 0, options: GUIXcodeSelection().options, report: XcodeDoctorReport(),
            xcodeRunning: false, unavailableSimulatorIDs: [], fingerprints: [:])
        let preview = GUIXcodeWorkflow.preview(plan)
        XCTAssertFalse(preview.canExecute)
        XCTAssertTrue(preview.blockedReason?.contains("No selected Xcode data") == true)
        XCTAssertFalse(preview.accepts(GUIActionConfirmation(previewID: preview.id, reviewed: true)))
    }

    private var root: URL!
    private var home: URL!
    private var volume: URL!
    private var runner: Runner!
    private var disks: Disks!
    private var core: MacBayService!
    private var live: LiveGUIService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gui-xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        volume = root.appendingPathComponent("volumes/External")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        runner = Runner()
        disks = Disks(volume: volume.path)
        let manager = VolumeManager(diskInfoProvider: disks, volumeMountPrefix: root.appendingPathComponent("volumes").path)
        core = MacBayService(commandRunner: runner, volumeManager: manager,
            configStore: ConfigStore(environment: [:], homeDirectory: home),
            historyStore: HistoryStore(environment: [:], homeDirectory: home),
            xcodeDoctor: XcodeDoctor(commandRunner: runner, volumeManager: manager, homeDirectory: home))
        live = LiveGUIService(service: core)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItemMakingWritable(at: root) }

    @discardableResult
    private func payload(_ name: String) throws -> URL {
        let path = home.appendingPathComponent("Library/Developer/Xcode/" + name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("fixture archive".utf8).write(to: path.appendingPathComponent("archive.bin"))
        return path
    }

    func testLiveXcodeMoveRequiresOneUseConfirmationAndRecordsManagedFolders() async throws {
        let device = try payload("iOS DeviceSupport")
        let archives = try payload("Archives")
        let derived = try payload("DerivedData")
        let preview = try await live.previewXcode(volumePath: volume.path, options: GUIXcodeSelection().options)
        XCTAssertTrue(runner.mutations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MacBayPaths.externalRoot(on: volume).path))
        XCTAssertFalse(preview.requiresXcodeRemovalConfirmation)
        let result = try await live.executeAction(GUIActionConfirmation(previewID: preview.id, reviewed: true), progress: { _ in })
        XCTAssertTrue(result.succeeded, result.messages.joined(separator: "\n"))
        XCTAssertEqual(runner.mutations.count, 2)
        XCTAssertFalse(runner.commands.contains { $0.contains("simctl") })
        for source in [device, archives] {
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("archive.bin")), Data("fixture archive".utf8))
        }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: derived.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived.appendingPathComponent("archive.bin").path))
        XCTAssertEqual(try ManifestStore().load(on: volume).items.count, 2)
        XCTAssertTrue(OperationJournal().listIncompleteMoves(on: volume).isEmpty)
        XCTAssertEqual(core.history(limit: 10).first?.outcome, .success)
        do {
            _ = try await live.executeAction(GUIActionConfirmation(previewID: preview.id, reviewed: true), progress: { _ in })
            XCTFail("A consumed preview must not run twice")
        } catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
        XCTAssertEqual(runner.mutations.count, 2)
    }

    func testLiveCleanupAcknowledgmentAndExactSimulatorTargets() async throws {
        let archives = try payload("Archives")
        let derived = try payload("DerivedData")
        var selection = GUIXcodeSelection()
        selection.moveDeviceSupport = false
        selection.moveArchives = false
        selection.derivedData = .clean
        selection.deleteUnavailableSimulators = true
        let preview = try await live.previewXcode(volumePath: volume.path, options: selection.options)
        XCTAssertTrue(preview.requiresXcodeRemovalConfirmation)
        XCTAssertTrue(preview.detail.rows.contains { $0.value.contains("SIM-UNAVAILABLE") })
        XCTAssertTrue(runner.mutations.isEmpty)
        do {
            _ = try await live.executeAction(GUIActionConfirmation(previewID: preview.id, reviewed: true), progress: { _ in })
            XCTFail("Destructive Xcode actions require their own acknowledgment")
        } catch { XCTAssertTrue(runner.mutations.isEmpty) }
        let fresh = try await live.previewXcode(volumePath: volume.path, options: selection.options)
        let result = try await live.executeAction(GUIActionConfirmation(previewID: fresh.id, reviewed: true, confirmsXcodeRemoval: true), progress: { _ in })
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.appendingPathComponent("archive.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archives.appendingPathComponent("archive.bin").path))
        XCTAssertTrue(runner.commands.contains(["simctl", "delete", "SIM-UNAVAILABLE"]))
        XCTAssertFalse(runner.commands.contains(["simctl", "delete", "unavailable"]))
    }

    func testLiveCancellationAndChangedPlanNeverMutateFiles() async throws {
        let archives = try payload("Archives")
        let cancelled = try await live.previewXcode(volumePath: volume.path, options: GUIXcodeSelection().options)
        await live.discardAction(cancelled.id)
        do {
            _ = try await live.executeAction(GUIActionConfirmation(previewID: cancelled.id, reviewed: true), progress: { _ in })
            XCTFail("Cancelled preview must not execute")
        } catch { XCTAssertTrue(runner.mutations.isEmpty) }
        let stale = try await live.previewXcode(volumePath: volume.path, options: GUIXcodeSelection().options)
        try Data("changed archive".utf8).write(to: archives.appendingPathComponent("archive.bin"))
        do {
            _ = try await live.executeAction(GUIActionConfirmation(previewID: stale.id, reviewed: true), progress: { _ in })
            XCTFail("Changed data requires a new preview")
        } catch { XCTAssertTrue(error is XcodePlanError) }
        XCTAssertTrue(runner.mutations.isEmpty)
        XCTAssertTrue(core.history(limit: 10).isEmpty)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: archives.path))
    }

    func testBackupCleanupFailureKeepsTheCompleteArchiveAndOffersRecordedRecoveryPaths() async throws {
        let archives = try payload("Archives")
        let fileManager = BackupRemovalFailure()
        let manager = VolumeManager(fileManager: fileManager, diskInfoProvider: disks,
            volumeMountPrefix: root.appendingPathComponent("volumes").path)
        let service = MacBayService(fileManager: fileManager, commandRunner: runner, volumeManager: manager,
            configStore: ConfigStore(environment: [:], homeDirectory: home),
            historyStore: HistoryStore(environment: [:], homeDirectory: home),
            xcodeDoctor: XcodeDoctor(fileManager: fileManager, commandRunner: runner, volumeManager: manager, homeDirectory: home))
        let live = LiveGUIService(service: service)
        let preview = try await live.previewXcode(volumePath: volume.path, options: GUIXcodeSelection().options)
        let result = try await live.executeAction(GUIActionConfirmation(previewID: preview.id, reviewed: true), progress: { _ in })
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.canOpenRecovery)
        let record = try XCTUnwrap(OperationJournal().listIncompleteMoves(on: volume).first)
        XCTAssertEqual(record.phase, .manifestSaved)
        XCTAssertTrue(result.paths.contains(try XCTUnwrap(record.backupPath)))
        XCTAssertEqual(try Data(contentsOf: archives.appendingPathComponent("archive.bin")), Data("fixture archive".utf8))
        XCTAssertTrue(result.messages.contains { $0.contains("backup may be incomplete") })
        XCTAssertEqual(try ManifestStore().load(on: volume).items.first?.sourcePath, archives.path)
    }

    func testLivePartialFailureReportsCompletedAndFailedActions() async throws {
        let device = try payload("iOS DeviceSupport")
        let archives = try payload("Archives")
        runner.failArchivesCopy = true
        let preview = try await live.previewXcode(volumePath: volume.path, options: GUIXcodeSelection().options)
        let result = try await live.executeAction(GUIActionConfirmation(previewID: preview.id, reviewed: true), progress: { _ in })
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.messages.contains { $0.contains("Fixture copy denied") })
        XCTAssertTrue(result.paths.contains(device.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.appendingPathComponent("archive.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archives.appendingPathComponent("archive.bin").path))
        XCTAssertEqual(core.history(limit: 10).first?.outcome, .partial)
    }

    private final class BackupRemovalFailure: FileManager, @unchecked Sendable {
        override func removeItem(at url: URL) throws {
            if url.lastPathComponent.contains(".macbay-") {
                try super.removeItem(at: url.appendingPathComponent("archive.bin"))
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try super.removeItem(at: url)
        }
    }

    private final class Runner: CommandRunner, @unchecked Sendable {
        var mutations: [[String]] = []
        var commands: [[String]] = []
        var failArchivesCopy = false
        func run(_ executable: String, arguments: [String]) throws -> CommandResult {
            commands.append(arguments)
            if executable.hasSuffix("pgrep") || executable.hasSuffix("lsof") { return CommandResult(status: 1) }
            if executable.hasSuffix("ditto") {
                mutations.append(arguments)
                let source = arguments[arguments.count - 2]
                if failArchivesCopy, URL(fileURLWithPath: source).lastPathComponent == "Archives" {
                    return CommandResult(status: 1, standardError: "Fixture copy denied")
                }
                try FileManager.default.copyItem(atPath: source, toPath: arguments.last!)
            }
            if arguments.contains("delete") { mutations.append(arguments) }
            return CommandResult(status: 0, standardOutput: "{\"devices\":{\"runtime\":[{\"udid\":\"SIM-UNAVAILABLE\",\"isAvailable\":false}]}}")
        }
    }

    private final class Disks: DiskInfoProvider, @unchecked Sendable {
        let volume: String
        init(volume: String) { self.volume = volume }
        func diskInfo(for path: String) throws -> VolumeDiskInfo {
            VolumeDiskInfo(mountPoint: volume, isInternal: false, filesystemType: "apfs", isWritableVolume: true,
                busProtocol: "USB", volumeName: "Fixture", totalBytes: 1_000_000, availableBytes: 900_000, volumeUUID: "FIXTURE")
        }
    }
}
