import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIStabilityTests: XCTestCase {
    @MainActor
    func testCannotPrepareAnAppActionBehindAnotherPresentedSheet() async {
        for presentation in ["setup", "release"] {
            let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
            await store.start()
            store.selectedApplicationID = "/Applications/Blender.app"
            switch presentation {
            case "setup": store.showsSetup = true
            default: store.showsReleaseCheck = true
            }
            await store.previewApplication()
            XCTAssertNil(store.actionPreview, presentation + " must keep app confirmation from opening behind it")
        }
    }

    @MainActor
    func testPreferencesWindowDoesNotBlockMainWindowNavigation() async {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        store.showsSettings = true
        store.selectedApplicationID = "/Applications/Blender.app"
        XCTAssertTrue(store.canNavigate)
        await store.previewApplication()
        XCTAssertNotNil(store.actionPreview)
        store.requestSetup()
        XCTAssertFalse(store.showsSetup, "Preferences must not start another workflow while a file action is reviewed")
    }

    @MainActor
    func testFinishingSetupWithoutOptingInNeverSavesADefault() async {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, isDemo: true, monitorVolumes: false)
        await store.refresh()
        await store.checkSetup()
        let completed = await store.finishSetup()
        XCTAssertTrue(completed)
        let writes = await fake.setupSaveCount()
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testSetupCannotReplaceAReviewedFileAction() async throws {
        let store = GUIStore(service: WorkflowGUIService(), isDemo: true, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(GUIUpdateRequest(action: .begin, appPath: "/Applications/Example.app"))
        let preview = try XCTUnwrap(store.actionPreview)
        store.requestSetup()
        XCTAssertFalse(store.showsSetup)
        XCTAssertEqual(store.actionPreview?.id, preview.id)
    }

    @MainActor
    func testOnlyOnePresentationIsDeferredWhileSettingsCloses() async {
        let store = GUIStore(service: WorkflowGUIService(), isDemo: true, monitorVolumes: false)
        store.showsSettings = true
        store.requestSetup()
        store.requestReleaseCheck()
        await store.checkForAppUpdates()
        store.settingsDismissed()
        XCTAssertTrue(store.showsSetup)
        XCTAssertFalse(store.showsReleaseCheck)
    }

    @MainActor
    func testReleaseCheckDoesNotOpenOverAStoragePreview() async {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        await store.previewXcode()
        XCTAssertNotNil(store.actionPreview)
        await store.checkForAppUpdates()
        XCTAssertFalse(store.showsReleaseCheck)
    }

    @MainActor
    func testReopeningAnInFlightReleaseCheckReusesTheRequest() async {
        let checker = SuspendedReleaseChecker()
        let store = GUIStore(service: WorkflowGUIService(), monitorVolumes: false, releaseChecker: checker)
        let check = Task { await store.checkForAppUpdates() }
        await checker.waitForRequest()
        store.showsReleaseCheck = false
        await store.checkForAppUpdates()
        XCTAssertTrue(store.showsReleaseCheck)
        let count = await checker.count
        XCTAssertEqual(count, 1)
        await checker.complete()
        await check.value
        XCTAssertNotNil(store.releaseInfo)
    }

    @MainActor
    func testDefaultSaveKeepsSetupOpenAndDefersRefreshUntilSaveFinishes() async {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, isDemo: true, monitorVolumes: false)
        await store.refresh()
        store.requestSetup()
        await store.checkSetup()
        await fake.holdSetupSave()
        let save = Task { await store.finishSetup(saveDefault: true) }
        await fake.waitForSetupSave()
        let initialReads = await fake.refreshCount()
        store.dismissSetup()
        await store.checkForAppUpdates()
        await store.refresh()
        let duringSaveReads = await fake.refreshCount()
        XCTAssertTrue(store.showsSetup)
        XCTAssertFalse(store.showsReleaseCheck)
        XCTAssertEqual(initialReads, duringSaveReads)
        await fake.releaseSetupSave()
        let finished = await save.value
        XCTAssertTrue(finished)
        XCTAssertFalse(store.showsSetup)
        let finalReads = await fake.refreshCount()
        XCTAssertGreaterThan(finalReads, initialReads)
        let saves = await fake.setupSaveCount()
        XCTAssertEqual(saves, 1)
    }
}

private actor SuspendedReleaseChecker: GUIReleaseChecking {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func check(installedVersion: String) async -> GUIReleaseInfo {
        count += 1
        await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
        return GUIReleaseInfo(status: .upToDate, installedVersion: installedVersion)
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func complete() { pending?.resume(); pending = nil }
}
