import Foundation
import XCTest
@testable import MacBayKit

final class UpdateWorkflowTests: XCTestCase {
    private var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testUpdatePlanIsReadOnlyAndExecutesTheReviewedWorkflow() throws {
        let plan = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        XCTAssertTrue(plan.report.dryRun)
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        _ = try fixture.service.executeAppUpdate(plan: plan)
        XCTAssertEqual(try fixture.service.updateStatus().first?.phase, .awaitingUpdate)
        let finish = try fixture.service.planAppUpdate(action: .finish, appPath: fixture.source.path)
        _ = try fixture.service.executeAppUpdate(plan: finish)
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
    }

    func testUpdatePlanRejectsSameSizeSourceChangesBeforeMutation() throws {
        let file = fixture.externalApp.appendingPathComponent("Contents/state.txt")
        try Data("before".utf8).write(to: file)
        let plan = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        try Data("after!".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try fixture.service.executeAppUpdate(plan: plan)) {
            XCTAssertTrue($0.localizedDescription.contains("conditions changed"))
        }
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
    }

    func testUpdatePlanRejectsWorkflowChanges() throws {
        let plan = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        let recorded = try fixture.service.updateStatus()
        XCTAssertThrowsError(try fixture.service.executeAppUpdate(plan: plan))
        XCTAssertEqual(try fixture.service.updateStatus(), recorded)
        XCTAssertFalse(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
    }

    func testUpdatePlanRechecksSignatureAndAllowsFreshRetry() throws {
        let plan = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        fixture.runner.verifyStatus = 1
        XCTAssertThrowsError(try fixture.service.executeAppUpdate(plan: plan))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        fixture.runner.verifyStatus = 0
        let fresh = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        _ = try fixture.service.executeAppUpdate(plan: fresh)
        XCTAssertEqual(try fixture.service.updateStatus().first?.phase, .awaitingUpdate)
    }

    func testUpdatePlanRechecksRunningProcesses() throws {
        let plan = try fixture.service.planAppUpdate(action: .begin, appPath: fixture.source.path)
        fixture.runner.lockedPath = fixture.externalApp.path + "/Contents/MacOS/kiro-cli"
        XCTAssertThrowsError(try fixture.service.executeAppUpdate(plan: plan))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
    }

    func testManagedUpdatePlanFailurePreservesLocalAppAndWorkflow() throws {
        let plan = try fixture.service.planAppUpdate(action: .managedKiro, appPath: fixture.source.path)
        fixture.runner.updateStatus = 1
        XCTAssertThrowsError(try fixture.service.executeAppUpdate(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        XCTAssertEqual(try fixture.service.updateStatus().first?.phase, .awaitingUpdate)
    }

    func testManagedUpdatePlanRejectsAnotherApplicationPath() {
        XCTAssertThrowsError(try fixture.service.planAppUpdate(action: .managedKiro,
            appPath: fixture.source.deletingLastPathComponent().appendingPathComponent("Other.app").path))
    }

    func testApplicationMoveAndRestorePlansUseTheReviewedVolume() throws {
        let restore = try fixture.service.planApplicationMigration(action: .restore, appPath: fixture.source.path,
                                                                    volumePath: "/Volumes/NotTheRecordedDrive")
        XCTAssertEqual(restore.volumePath, fixture.volume.path)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        _ = try fixture.service.executeApplicationMigration(plan: restore)
        XCTAssertFalse(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        let move = try fixture.service.planApplicationMigration(action: .move, appPath: fixture.source.path,
                                                                 volumePath: fixture.volume.path)
        _ = try fixture.service.executeApplicationMigration(plan: move)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.source.path), fixture.externalApp.path)
    }

    func testMigrationRejectsReplacedDriveAndChangedSourceBeforeCopying() throws {
        let restore = try fixture.service.planApplicationMigration(action: .restore, appPath: fixture.source.path)
        fixture.setExternalUUID("ANOTHER-DRIVE")
        XCTAssertThrowsError(try fixture.service.executeApplicationMigration(plan: restore))
        fixture.setExternalUUID("UPDATE-TEST-UUID")
        let file = fixture.externalApp.appendingPathComponent("Contents/MacOS/kiro-cli")
        try Data("changed".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try fixture.service.executeApplicationMigration(plan: restore))
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.externalApp.path))
    }

    func testMigrationRechecksProcessesAndDoesNotRestoreUnmanagedLinks() throws {
        let plan = try fixture.service.planApplicationMigration(action: .restore, appPath: fixture.source.path)
        fixture.runner.lockedPath = fixture.externalApp.appendingPathComponent("Contents/MacOS/kiro-cli").path
        XCTAssertThrowsError(try fixture.service.executeApplicationMigration(plan: plan))
        fixture.runner.lockedPath = nil
        try ManifestStore().updating(on: fixture.volume) { $0.items = [] }
        XCTAssertThrowsError(try fixture.service.planApplicationMigration(action: .restore, appPath: fixture.source.path))
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
    }

    func testDefaultDrivePreviewDoesNotSaveAndChangedConfigurationIsRejected() throws {
        let plan = try fixture.service.planDefaultVolume(volumePath: fixture.volume.path)
        XCTAssertNil(try fixture.service.showConfig().defaultVolume)
        _ = try fixture.service.executeDefaultVolume(plan: plan)
        let saved = try fixture.service.showConfig().defaultVolume
        XCTAssertEqual(saved?.uuid, "UPDATE-TEST-UUID")
        XCTAssertThrowsError(try fixture.service.executeDefaultVolume(plan: plan))
        XCTAssertEqual(try fixture.service.showConfig().defaultVolume, saved)
    }

    func testDefaultDriveCannotBeReplacedOrDisconnectedWhileSetupIsOpen() throws {
        let plan = try fixture.service.planDefaultVolume(volumePath: fixture.volume.path)
        fixture.setExternalUUID("DIFFERENT-DRIVE")
        XCTAssertThrowsError(try fixture.service.executeDefaultVolume(plan: plan))
        fixture.fileManager.mountedPaths = ["/"]
        XCTAssertThrowsError(try fixture.service.executeDefaultVolume(plan: plan))
        XCTAssertNil(try fixture.service.showConfig().defaultVolume)
    }

    func testBeginAndFinishRestoresUpdatedAppAndClearsWorkflow() throws {
        let preview = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: true)
        XCTAssertTrue(preview.dryRun)
        XCTAssertTrue(FileManager.default.destinationOfSymbolicLinkIfExists(fixture.source))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)

        let begun = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        XCTAssertEqual(begun.record.phase, .awaitingUpdate)
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        try fixture.writeMetadata(version: "2.23.1", build: "22301")
        let finishPreview = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: true)
        XCTAssertEqual(finishPreview.currentVersion, "2.23.1")
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        let finished = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertEqual(finished.currentVersion, "2.23.1")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.source.path),
            fixture.externalApp.path
        )
        XCTAssertEqual(try fixture.service.updateStatus(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.readVersion(at: fixture.externalApp), "2.23.1")
        let manifest = try ManifestStore().load(on: fixture.volume)
        XCTAssertTrue(manifest.items.contains { $0.sourcePath == fixture.source.path && $0.externalPath == fixture.externalApp.path })
    }

    func testBundleIdentifierMismatchKeepsLocalAppAndAllowsRetry() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        try fixture.writeMetadata(bundleIdentifier: "com.example.different", version: "2.23.1", build: "22301")

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false))
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        try fixture.writeMetadata(version: "2.23.1", build: "22301")
        _ = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testAlreadyReExternalizedAppMustStillMatchRecordedBundleIdentifier() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        try fixture.writeMetadata(bundleIdentifier: "com.example.replaced", version: "2.23.1", build: "22301")
        _ = try fixture.service.dock(
            appName: fixture.source.path,
            volumePath: fixture.volume.path,
            dryRun: false
        )

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false))
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)
    }

    func testSignatureFailureLeavesAppLocalAndFinishCanBeRetried() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        try fixture.writeMetadata(version: "2.23.1", build: "22301")
        fixture.runner.verifyStatus = 1

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)) { error in
            guard case MacBayError.signatureVerificationFailed = error else {
                return XCTFail("Expected signatureVerificationFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        fixture.runner.verifyStatus = 0
        _ = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testDetachedVolumePreservesLocalAppAndWorkflowForRetry() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        fixture.fileManager.mountedPaths = ["/"]

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        fixture.fileManager.mountedPaths = ["/", fixture.volume.path]
        _ = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testVolumeUUIDMismatchPreservesLocalAppAndAllowsRetry() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        fixture.setExternalUUID("REPLACEMENT-VOLUME-UUID")

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false))
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        fixture.setExternalUUID("UPDATE-TEST-UUID")
        _ = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testManagedKiroUpdateReturnsAppToOriginalVolumeAndDisablesBackgroundUpdates() throws {
        let result = try fixture.service.runKiroUpdate(dryRun: false)

        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.currentVersion, "2.23.1")
        XCTAssertTrue(result.messages.contains { $0.contains("background updates are disabled") })
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertEqual(try fixture.readVersion(at: fixture.externalApp), "2.23.1")
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertTrue(fixture.runner.calledArguments.contains(["settings", "app.disableAutoupdates", "true"]))
        XCTAssertTrue(fixture.runner.calledArguments.contains(["update", "--non-interactive"]))
        XCTAssertTrue(fixture.runner.calledArguments.contains(["settings", "list", "--format", "json"]))
    }

    func testManagedKiroUpdateWithNoAvailableUpdateStillCompletesSafely() throws {
        fixture.runner.updateChangesVersion = false

        let result = try fixture.service.runKiroUpdate(dryRun: false)

        XCTAssertEqual(result.currentVersion, "2.21.3")
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertEqual(try fixture.readVersion(at: fixture.externalApp), "2.21.3")
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testManagedKiroUpdaterFailureKeepsVerifiedAppLocalForRetry() throws {
        fixture.runner.updateStatus = 17

        XCTAssertThrowsError(try fixture.service.runKiroUpdate(dryRun: false))

        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)
        XCTAssertEqual(try fixture.readVersion(at: fixture.source), "2.21.3")
    }

    func testManagedKiroUpdateStopsIfBackgroundSettingCannotBeVerified() throws {
        fixture.runner.settingsJSON = "{\"app.disableAutoupdates\":false}"

        XCTAssertThrowsError(try fixture.service.runKiroUpdate(dryRun: false))

        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)
        XCTAssertFalse(fixture.runner.calledArguments.contains(["update", "--non-interactive"]))
    }

    func testManagedKiroUpdatePreviewDoesNotChangeAppOrSettings() throws {
        let result = try fixture.service.runKiroUpdate(dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
        XCTAssertFalse(fixture.runner.calledArguments.contains(["settings", "app.disableAutoupdates", "true"]))
    }

    func testDockAndAdoptResultsWarnAboutExternalSelfUpdaters() {
        let dock = MigrationResult(
            operation: "dock", name: "Demo.app", sourcePath: "/Applications/Demo.app",
            destinationPath: "/Volumes/External/MacBay/Applications/Demo.app", sizeBytes: 1,
            dryRun: true, messages: []
        )
        let adopt = MigrationResult(
            operation: "adopt", name: "Demo.app", sourcePath: "/Applications/Demo.app",
            destinationPath: "/Volumes/External/MacBay/Applications/Demo.app", sizeBytes: 1,
            dryRun: true, messages: []
        )
        let undock = MigrationResult(
            operation: "undock", name: "Demo.app", sourcePath: "/Volumes/External/MacBay/Applications/Demo.app",
            destinationPath: "/Applications/Demo.app", sizeBytes: 1, dryRun: true, messages: []
        )

        XCTAssertTrue(dock.messages.contains { $0.contains("mb update begin Demo.app") })
        XCTAssertTrue(dock.messages.contains { $0.contains("mb update finish Demo.app") })
        XCTAssertTrue(adopt.messages.contains { $0.contains("mb update begin Demo.app") })
        XCTAssertTrue(undock.messages.isEmpty)
    }

    func testRunningAppPreventsBeginWithoutChangingLinkOrState() throws {
        fixture.runner.lockedPath = fixture.externalApp.path

        XCTAssertThrowsError(try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)) { error in
            guard case MacBayError.activeProcesses = error else {
                return XCTFail("Expected activeProcesses, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }

    func testInsufficientSpacePreservesLocalAppAndWorkflowForRetry() throws {
        _ = try fixture.service.beginAppUpdate(appName: fixture.source.path, dryRun: false)
        fixture.setExternalAvailableBytes(0)

        XCTAssertThrowsError(try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)) { error in
            guard case MacBayError.insufficientSpace = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try fixture.service.updateStatus().count, 1)

        fixture.setExternalAvailableBytes(20_000_000_000)
        _ = try fixture.service.finishAppUpdate(appName: fixture.appName, dryRun: false)
        XCTAssertTrue(FileManager.default.isSymbolicLinkAtPath(fixture.source.path))
        XCTAssertTrue(try fixture.service.updateStatus().isEmpty)
    }
}

final class RepairRollbackPlanTests: XCTestCase {
    private var fixture: Fixture!
    override func setUpWithError() throws { fixture = try Fixture() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixture.root); fixture = nil }

    func testRollbackPlanOnlyInspectsUntilConfirmedAndRestoresRecordedState() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        XCTAssertEqual(plan.record, record)
        XCTAssertNotNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
        _ = try fixture.service.executeRepairRollback(plan: plan)
        XCTAssertNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.localPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.externalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.stagingPath))
    }

    func testChangedJournalPreventsRollback() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        try DarwinRepairJournal().save(record.updatingPhase(.started), on: fixture.volume)
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
        XCTAssertNotNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
    }

    func testChangedStagingOrSourcePreventsRollback() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        let file = URL(fileURLWithPath: record.stagingPath).appendingPathComponent("Contents/MacOS/kiro-cli")
        try Data("changed executable".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
    }

    func testReplacedVolumePreventsRollbackAndFreshPreviewCanRetry() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        fixture.setExternalUUID("ANOTHER-VOLUME")
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
        fixture.setExternalUUID("UPDATE-TEST-UUID")
        let fresh = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        _ = try fixture.service.executeRepairRollback(plan: fresh)
        XCTAssertNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
    }

    func testMissingVolumeAndRunningAppPreventRollback() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        fixture.fileManager.mountedPaths = ["/"]
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan))
        fixture.fileManager.mountedPaths = ["/", fixture.volume.path]
        fixture.runner.lockedPath = record.localPath + "/Contents/MacOS/kiro-cli"
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
    }

    func testRedirectedStagingParentStaysReadOnly() throws {
        let record = try fixture.interruptRepair()
        let parent = URL(fileURLWithPath: record.stagingPath).deletingLastPathComponent()
        let other = MacBayPaths.operationsRoot(on: fixture.volume).appendingPathComponent("another-operation")
        try FileManager.default.moveItem(at: parent, to: other)
        try FileManager.default.createSymbolicLink(atPath: parent.path, withDestinationPath: other.path)
        XCTAssertThrowsError(try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent(record.appName).path))
    }

    func testAdditionalStagingDataIsNeverIncludedInRollbackCleanup() throws {
        let record = try fixture.interruptRepair()
        let extra = URL(fileURLWithPath: record.stagingPath).deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: extra)
        XCTAssertThrowsError(try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath))
        XCTAssertEqual(try String(contentsOf: extra), "preserve")
        XCTAssertNotNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
    }

    func testPartialCleanupFailureKeepsJournalAndRemainingStaging() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        fixture.fileManager.failOnRemoval = record.stagingPath
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan)) {
            XCTAssertTrue($0.localizedDescription.contains("Rollback incomplete"))
        }
        XCTAssertNotNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
        fixture.fileManager.failOnRemoval = nil
        let fresh = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        _ = try fixture.service.executeRepairRollback(plan: fresh)
    }

    func testAmbiguousPhaseAndInvalidSignatureStayReadOnly() throws {
        let record = try fixture.interruptRepair()
        try DarwinRepairJournal().save(record.updatingPhase(.linked), on: fixture.volume)
        XCTAssertThrowsError(try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath))
        try DarwinRepairJournal().save(record, on: fixture.volume)
        fixture.runner.verifyStatus = 1
        XCTAssertThrowsError(try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.stagingPath))
    }

    func testJournalCleanupFailureIsReportedAndCanBeRetried() throws {
        let record = try fixture.interruptRepair()
        let plan = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        fixture.fileManager.failOnRemoval = MacBayPaths.operationsRoot(on: fixture.volume)
            .appendingPathComponent("repair-" + record.appName + ".json").path
        XCTAssertThrowsError(try fixture.service.executeRepairRollback(plan: plan)) {
            XCTAssertTrue($0.localizedDescription.contains("journal could not be cleared"))
        }
        XCTAssertNotNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.localPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.externalPath))
        fixture.fileManager.failOnRemoval = nil
        let fresh = try fixture.service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
        _ = try fixture.service.executeRepairRollback(plan: fresh)
        XCTAssertNil(DarwinRepairJournal().load(appName: record.appName, on: fixture.volume))
    }
}

private extension FileManager {
    func isSymbolicLinkAtPath(_ path: String) -> Bool {
        (try? attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func destinationOfSymbolicLinkIfExists(_ url: URL) -> Bool {
        (try? destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private final class UpdateWorkflowTestFileManager: FileManager, @unchecked Sendable {
    var mountedPaths: [String]
    var failOnRemoval: String?

    override func removeItem(at URL: URL) throws {
        if URL.path == failOnRemoval { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }

    init(mountedPaths: [String]) {
        self.mountedPaths = mountedPaths
        super.init()
    }

    override func mountedVolumeURLs(
        includingResourceValuesForKeys propertyKeys: [URLResourceKey]?,
        options: FileManager.VolumeEnumerationOptions = []
    ) -> [URL]? {
        mountedPaths.map { URL(fileURLWithPath: $0) }
    }
}

private final class UpdateWorkflowTestCommandRunner: CommandRunner, @unchecked Sendable {
    var verifyStatus: Int32 = 0
    var updateStatus: Int32 = 0
    var settingsStatus: Int32 = 0
    var updateChangesVersion = true
    var settingsJSON = "{\"app.disableAutoupdates\":true}"
    var lockedPath: String?
    var calledArguments: [[String]] = []

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        calledArguments.append(arguments)
        if arguments == ["settings", "app.disableAutoupdates", "true"] {
            return CommandResult(status: settingsStatus, standardOutput: "", standardError: "settings failed")
        }
        if arguments == ["settings", "list", "--format", "json"] {
            return CommandResult(
                status: 0,
                standardOutput: settingsJSON,
                standardError: ""
            )
        }
        if arguments == ["update", "--non-interactive"] {
            guard updateStatus == 0 else {
                return CommandResult(status: updateStatus, standardOutput: "", standardError: "update failed")
            }
            let infoURL = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: infoURL)
            var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            if updateChangesVersion {
                info["CFBundleShortVersionString"] = "2.23.1"
                info["CFBundleVersion"] = "22301"
                let updated = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try updated.write(to: infoURL, options: .atomic)
            }
            return CommandResult(status: 0, standardOutput: "Update check completed", standardError: "")
        }
        if arguments == ["--version"] {
            let infoURL = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: infoURL)
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            return CommandResult(status: 0, standardOutput: "kiro-cli \(info["CFBundleShortVersionString"] as? String ?? "unknown")\n", standardError: "")
        }
        if arguments.contains("--entitlements") {
            return CommandResult(status: 0, standardOutput: "<plist><dict></dict></plist>", standardError: "")
        }
        if arguments.contains("--verify") {
            return CommandResult(status: verifyStatus, standardOutput: "", standardError: "signature rejected")
        }
        if arguments.contains("-nP") {
            guard let lockedPath else {
                return CommandResult(status: 1, standardOutput: "", standardError: "")
            }
            return CommandResult(
                status: 0,
                standardOutput: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nKiro 123 tester 1r REG 1,2 100 42 \(lockedPath)\n",
                standardError: ""
            )
        }
        if executable.contains("ditto") {
            let source = arguments[arguments.count - 2]
            let destination = arguments[arguments.count - 1]
            try FileManager.default.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        }
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}

private final class Fixture {
    let root: URL
    let volume: URL
    let source: URL
    let externalApp: URL
    let appName = "Kiro CLI.app"
    let fileManager: UpdateWorkflowTestFileManager
    let diskInfo: MutableUpdateWorkflowDiskInfoProvider
    let runner: UpdateWorkflowTestCommandRunner
    let service: MacBayService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        volume = root.appendingPathComponent("Volumes/External", isDirectory: true)
        source = root.appendingPathComponent("Applications/Kiro CLI.app", isDirectory: true)
        externalApp = MacBayPaths.applicationsRoot(on: volume).appendingPathComponent("Kiro CLI.app", isDirectory: true)
        try FileManager.default.createDirectory(at: MacBayPaths.applicationsRoot(on: volume), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeApp(at: externalApp, version: "2.21.3", build: "22103")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: externalApp.path)

        let volumeInfo = VolumeDiskInfo(
            mountPoint: volume.path,
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: "External",
            totalBytes: 500_000_000_000,
            availableBytes: 20_000_000_000,
            volumeUUID: "UPDATE-TEST-UUID"
        )
        let internalInfo = VolumeDiskInfo(
            mountPoint: "/",
            isInternal: true,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "Apple Silicon",
            volumeName: "Internal",
            totalBytes: 1_000_000_000_000,
            availableBytes: 400_000_000_000,
            volumeUUID: "INTERNAL-TEST-UUID"
        )
        fileManager = UpdateWorkflowTestFileManager(mountedPaths: ["/", volume.path])
        diskInfo = MutableUpdateWorkflowDiskInfoProvider(["/": internalInfo, volume.path: volumeInfo])
        runner = UpdateWorkflowTestCommandRunner()
        let volumeManager = VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: diskInfo,
            volumeMountPrefix: root.appendingPathComponent("Volumes").path
        )
        let state = root.appendingPathComponent("state")
        let env = ["XDG_STATE_HOME": state.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path]
        service = MacBayService(
            fileManager: fileManager,
            commandRunner: runner,
            volumeManager: volumeManager,
            configStore: ConfigStore(fileManager: fileManager, environment: env, homeDirectory: root),
            updateWorkflowStore: UpdateWorkflowStore(fileManager: fileManager, environment: env, homeDirectory: root),
            historyStore: HistoryStore(fileManager: fileManager, environment: env, homeDirectory: root),
            applicationsDirectory: source.deletingLastPathComponent()
        )

        try ManifestStore(fileManager: fileManager).updating(on: volume) { manifest in
            manifest.items = [DockedItem(
                name: appName,
                sourcePath: source.path,
                externalPath: externalApp.path,
                sizeBytes: 128,
                kind: .application,
                dockedAt: macBayTimestamp()
            )]
        }
    }

    func interruptRepair() throws -> RepairJournalRecord {
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: externalApp, to: source)
        let id = UUID().uuidString
        let staging = MacBayPaths.operationsRoot(on: volume).appendingPathComponent(".staging-" + id).appendingPathComponent(appName)
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: staging)
        let item = try XCTUnwrap(ManifestStore().load(on: volume).items.first)
        let record = RepairJournalRecord(id: id, appName: appName, localPath: source.path,
            externalPath: externalApp.path,
            backupPath: MacBayPaths.backupsRoot(on: volume).appendingPathComponent(id).appendingPathComponent(appName).path,
            stagingPath: staging.path,
            localBackupPath: source.deletingLastPathComponent().appendingPathComponent("." + appName + ".macbay-local-backup-" + id).path,
            volumePath: volume.path, phase: .staged, timestamp: macBayTimestamp(), originalManifestItem: item)
        try DarwinRepairJournal().save(record, on: volume)
        return record
    }

    func writeMetadata(
        bundleIdentifier: String = "com.amazon.codewhisperer",
        version: String,
        build: String
    ) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "kiro-cli"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: source.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    }

    func readVersion(at app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }

    func setExternalAvailableBytes(_ bytes: UInt64) {
        guard let current = diskInfo.mapping[volume.path] else { return }
        diskInfo.mapping[volume.path] = VolumeDiskInfo(
            mountPoint: current.mountPoint,
            isInternal: current.isInternal,
            filesystemType: current.filesystemType,
            isWritableVolume: current.isWritableVolume,
            busProtocol: current.busProtocol,
            volumeName: current.volumeName,
            totalBytes: current.totalBytes,
            availableBytes: bytes,
            volumeUUID: current.volumeUUID
        )
    }

    func setExternalUUID(_ value: String) {
        guard let current = diskInfo.mapping[volume.path] else { return }
        diskInfo.mapping[volume.path] = VolumeDiskInfo(
            mountPoint: current.mountPoint,
            isInternal: current.isInternal,
            filesystemType: current.filesystemType,
            isWritableVolume: current.isWritableVolume,
            busProtocol: current.busProtocol,
            volumeName: current.volumeName,
            totalBytes: current.totalBytes,
            availableBytes: current.availableBytes,
            volumeUUID: value
        )
    }

    private static func makeApp(at url: URL, version: String, build: String) throws {
        let executableDirectory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try Data("fake signed executable".utf8).write(to: executableDirectory.appendingPathComponent("kiro-cli"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.amazon.codewhisperer",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "kiro-cli",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}

private final class MutableUpdateWorkflowDiskInfoProvider: DiskInfoProvider, @unchecked Sendable {
    var mapping: [String: VolumeDiskInfo]

    init(_ mapping: [String: VolumeDiskInfo]) {
        self.mapping = mapping
    }

    func diskInfo(for path: String) throws -> VolumeDiskInfo {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let exact = mapping[path] ?? mapping[standardized] { return exact }
        for (key, info) in mapping.sorted(by: { $0.key.count > $1.key.count }) {
            let normalizedKey = URL(fileURLWithPath: key).standardizedFileURL.path
            if standardized.hasPrefix(normalizedKey) { return info }
        }
        throw MacBayError.invalidVolume("No test disk metadata for \(path)")
    }
}
