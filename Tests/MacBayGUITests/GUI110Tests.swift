import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUI110Tests: XCTestCase {
    @MainActor
    func testDemoMoveAndRestoreRequireConfirmationAndRefreshTheirRows() async throws {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        let path = "/Applications/Blender.app"
        store.selectedApplicationID = path
        await store.previewApplication()
        let move = try XCTUnwrap(store.actionPreview)
        XCTAssertEqual(move.kind, .migration(.move))
        XCTAssertEqual(store.selectedApplication?.state, .ready)
        await store.confirmAction(GUIActionConfirmation(previewID: move.id, reviewed: true))
        XCTAssertEqual(store.applications.first { $0.path == path }?.state, .external)
        store.dismissAction()
        store.appLocation = .external
        store.selectedApplicationID = path
        await store.previewApplication()
        let restore = try XCTUnwrap(store.actionPreview)
        XCTAssertEqual(restore.kind, .migration(.restore))
        await store.confirmAction(GUIActionConfirmation(previewID: restore.id, reviewed: true))
        XCTAssertEqual(store.applications.first { $0.path == path }?.state, .ready)
    }

    @MainActor
    func testCleanupRequiresExplicitPermanentRemovalAcknowledgment() async throws {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        await store.scanCaches()
        let cache = try XCTUnwrap(store.cacheItems.first { !$0.isRunning })
        store.selectedCacheIDs = [cache.id]
        await store.previewCleanup()
        let preview = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        XCTAssertNil(store.actionResult)
        XCTAssertTrue(store.cacheItems.contains { $0.id == cache.id })
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true, confirmsCacheRemoval: true))
        XCTAssertTrue(try XCTUnwrap(store.actionResult).succeeded)
        XCTAssertFalse(store.cacheItems.contains { $0.id == cache.id })
    }

    @MainActor
    func testChangingCacheSelectionInvalidatesTheReviewedCleanup() async throws {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        await store.scanCaches()
        store.selectedCacheIDs = [GUIExamples.caches[0].id]
        await store.previewCleanup()
        let preview = try XCTUnwrap(store.actionPreview)
        store.selectedCacheIDs = [GUIExamples.caches[1].id]
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true, confirmsCacheRemoval: true))
        XCTAssertNil(store.actionResult)
        XCTAssertEqual(store.cacheItems.count, GUIExamples.caches.count)
    }

    @MainActor
    func testSetupChecksDoNotSaveUntilExplicitFinish() async {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.checkSetup()
        let before = await fake.setupSaveCount()
        XCTAssertEqual(before, 0)
        let completed = await store.finishSetup(saveDefault: true)
        XCTAssertTrue(completed)
        let after = await fake.setupSaveCount()
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testChangedDriveAndSaveFailureKeepSetupUnfinished() async {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        store.showsSetup = true
        await store.checkSetup()
        store.selectedVolumePath = nil
        let stale = await store.finishSetup(saveDefault: true)
        XCTAssertFalse(stale)
        store.selectedVolumePath = GUIExamples.status.externalVolumes[0].path
        await store.checkSetup()
        await fake.failSetupSave()
        let failed = await store.finishSetup(saveDefault: true)
        XCTAssertFalse(failed)
        XCTAssertTrue(store.showsSetup)
        XCTAssertNotNil(store.setupError)
    }

    @MainActor
    func testSetupWithoutDriveOrCancelNeverWritesADefault() async {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.checkSetup()
        let completed = await store.finishSetup(saveDefault: false)
        XCTAssertTrue(completed)
        let saved = await fake.setupSaveCount()
        XCTAssertEqual(saved, 0)
        store.dismissSetup()
        XCTAssertNil(store.setupReport)
    }

    @MainActor
    func testReleaseChecksAreManualAndDemoNeverUsesTheNetworkChecker() async {
        let checker = ReleaseCheckSpy()
        let store = GUIStore(service: WorkflowGUIService(), monitorVolumes: false, releaseChecker: checker)
        await store.start()
        let initial = await checker.count
        XCTAssertEqual(initial, 0)
        await store.checkForAppUpdates()
        let requested = await checker.count
        XCTAssertEqual(requested, 1)
        XCTAssertNotNil(store.releaseInfo)
        let demo = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false, releaseChecker: checker)
        await demo.checkForAppUpdates()
        let afterDemo = await checker.count
        XCTAssertEqual(afterDemo, 1)
    }
}

private actor ReleaseCheckSpy: GUIReleaseChecking {
    var count = 0
    func check(installedVersion: String) -> GUIReleaseInfo {
        count += 1
        return GUIReleaseInfo(status: .upToDate, installedVersion: installedVersion, latestVersion: installedVersion)
    }
}
