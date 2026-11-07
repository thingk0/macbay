import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIStoreTests: XCTestCase {
    @MainActor
    func testPackagedArtworkLoadsWithoutAnAssetCatalog() {
        XCTAssertNotNil(GUIAssets.bundle.url(forResource: "AppIcon", withExtension: "png"))
        XCTAssertTrue(GUIAssets.icon.isValid)
        XCTAssertGreaterThan(GUIAssets.icon.size.width, 0)
    }

    func testUnsafeAndUnmanagedApplicationsCannotPrepareMoveOrRestore() {
        let unmanaged = ExternalApplication(name: "Manual.app", sourcePath: "/Applications/Manual.app",
            destinationPath: "/Volumes/KLEVV/Manual.app", sizeBytes: 10, managementStatus: .unmanaged)
        let scan = ScanReport(generatedAt: "", minimumApplicationSizeBytes: 0,
            candidates: GUIExamples.scan.candidates, externalApplications: [unmanaged])
        let rows = GUIApplication.rows(scan: scan, status: GUIExamples.status)
        XCTAssertFalse(rows.first { $0.name == "Docker.app" }!.canPreview)
        XCTAssertFalse(rows.first { $0.name == "Manual.app" }!.canPreview)
        XCTAssertTrue(rows.first { $0.name == "Xcode.app" }!.canPreview)
    }

    func testDisconnectedRecordedAppIsUnavailableAndUnknownSizeStaysUnknown() {
        let disconnected = StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
                                        externalVolumes: [], dockedItems: [])
        let rows = GUIApplication.rows(scan: GUIExamples.scan, status: disconnected)
        let app = rows.first { $0.name == "Visual Studio Code.app" }!
        XCTAssertEqual(app.state, .unavailable)
        XCTAssertFalse(app.canPreview)
        XCTAssertEqual(GUIFormat.bytes(nil), "Unknown")
    }

    @MainActor
    func testMultipleDrivesRequireAnExplicitSelection() async {
        let fake = ControlledGUIService()
        let second = StorageVolume(name: "Second", path: "/Volumes/Second", isInternal: false,
                                   totalBytes: 100, availableBytes: 90)
        await fake.setStatus(StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
            externalVolumes: GUIExamples.status.externalVolumes + [second], dockedItems: []))
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        XCTAssertNil(store.selectedVolumePath)
    }

    @MainActor
    func testMissingDefaultDoesNotSilentlySwitchToAnotherDrive() async {
        let fake = ControlledGUIService()
        await fake.setStatus(StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
            externalVolumes: GUIExamples.status.externalVolumes,
            defaultVolume: StatusDefaultVolume(name: "Missing", path: "/Volumes/Missing"), dockedItems: []))
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        XCTAssertNil(store.selectedVolumePath)
    }

    @MainActor
    func testLatePreviewIsDiscardedWhenApplicationSelectionChanges() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.start()
        store.selectedApplicationID = "/Applications/Android Studio.app"
        let request = Task { await store.previewApplication() }
        await fake.waitForPreview()
        store.selectedApplicationID = "/Applications/Blender.app"
        await fake.completePreview()
        await request.value
        XCTAssertNil(store.actionPreview)
        XCTAssertFalse(store.isPreparingPreview)
    }

    @MainActor
    func testDisconnectInvalidatesAnInFlightPreview() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.start()
        store.selectedApplicationID = "/Applications/Android Studio.app"
        let request = Task { await store.previewApplication() }
        await fake.waitForPreview()
        await fake.setStatus(StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
                                         externalVolumes: [], dockedItems: []))
        await store.refresh()
        await fake.completePreview()
        await request.value
        XCTAssertNil(store.actionPreview)
        XCTAssertNil(store.selectedVolumePath)
        XCTAssertFalse(store.canPreviewApplication)
    }

    @MainActor
    func testFailedHealthReadNeverAppearsHealthy() async {
        let fake = ControlledGUIService()
        await fake.failDoctor()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        XCTAssertNil(store.attentionCount)
        XCTAssertNil(store.doctorReport)
        XCTAssertNotNil(store.doctorError)
    }

    func testDemoCleanupRejectsRunningAppCaches() async throws {
        let service = DemoGUIService()
        do {
            _ = try await service.previewCaches(GUIExamples.caches.filter(\.isRunning))
            XCTFail("Running applications must not be included")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not running")) }
    }

    @MainActor
    func testMenuBarPollingUpdatesTheSharedStatusWithoutDiscardingAReviewedPreview() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.start()
        store.selectedApplicationID = "/Applications/Android Studio.app"
        let request = Task { await store.previewApplication() }
        await fake.waitForPreview()
        await fake.completePreview()
        await request.value
        let previewID = store.actionPreview?.id
        XCTAssertNotNil(previewID)
        let refreshed = StorageVolume(name: "Mac", path: "/", isInternal: true, totalBytes: 1000, availableBytes: 300)
        await fake.setStatus(StatusReport(generatedAt: "new", internalVolume: refreshed,
            externalVolumes: GUIExamples.status.externalVolumes, dockedItems: []))
        let doctorReads = await fake.doctorReads
        await store.refreshStorage()
        XCTAssertEqual(store.statusReport?.internalVolume, refreshed)
        XCTAssertEqual(store.actionPreview?.id, previewID)
        XCTAssertEqual(store.selectedVolumePath, GUIExamples.status.externalVolumes.first?.path)
        let currentDoctorReads = await fake.doctorReads
        XCTAssertEqual(currentDoctorReads, doctorReads)
    }

    @MainActor
    func testMenuBarPollingOnDisconnectInvalidatesTheReviewedDestination() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.start()
        store.selectedApplicationID = "/Applications/Android Studio.app"
        let request = Task { await store.previewApplication() }
        await fake.waitForPreview()
        await fake.completePreview()
        await request.value
        XCTAssertNotNil(store.actionPreview)
        await fake.setStatus(StatusReport(generatedAt: "", internalVolume: GUIExamples.status.internalVolume,
            externalVolumes: [], dockedItems: []))
        await store.refreshStorage()
        XCTAssertNil(store.selectedVolumePath)
        XCTAssertNil(store.actionPreview)
        XCTAssertTrue(store.statusReport?.externalVolumes.isEmpty == true)
    }

    @MainActor
    func testFailedMenuBarReadClearsPreviouslyDisplayedCapacity() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        XCTAssertNotNil(store.statusReport)
        await fake.failStatus()
        await store.refreshStorage()
        XCTAssertNil(store.statusReport)
        XCTAssertNil(store.selectedVolumePath)
        XCTAssertNotNil(store.statusError)
    }

    @MainActor
    func testLateMenuBarReadCannotOverwriteANewerFullRefresh() async {
        let fake = ControlledGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await fake.holdNextStatus()
        let poll = Task { await store.refreshStorage() }
        await fake.waitForStatus()
        let newStatus = StatusReport(generatedAt: "newer", internalVolume: GUIExamples.status.internalVolume,
            externalVolumes: [], dockedItems: [])
        await fake.setStatus(newStatus)
        await store.refresh()
        await fake.completeStatus()
        await poll.value
        XCTAssertEqual(store.statusReport, newStatus)
        XCTAssertNil(store.selectedVolumePath)
    }
}

private actor ControlledGUIService: GUIServiceProtocol {
    var currentStatus = GUIExamples.status
    var doctorFails = false
    var statusFails = false
    var doctorReads = 0
    var holdsNextStatus = false
    var pendingStatus: (CheckedContinuation<StatusReport, Error>, StatusReport)?
    var statusObserver: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<GUIActionPreview, Error>?
    var observer: CheckedContinuation<Void, Never>?
    func setStatus(_ status: StatusReport) { currentStatus = status }
    func failDoctor() { doctorFails = true }
    func failStatus() { statusFails = true }
    func status() async throws -> StatusReport {
        if statusFails { throw GUIError.unavailable("Storage could not be read") }
        if holdsNextStatus {
            holdsNextStatus = false
            return try await withCheckedThrowingContinuation { continuation in
                pendingStatus = (continuation, currentStatus)
                statusObserver?.resume()
                statusObserver = nil
            }
        }
        return currentStatus
    }
    func holdNextStatus() { holdsNextStatus = true }
    func waitForStatus() async {
        if pendingStatus != nil { return }
        await withCheckedContinuation { statusObserver = $0 }
    }
    func completeStatus() {
        if let (continuation, result) = pendingStatus { continuation.resume(returning: result) }
        pendingStatus = nil
    }
    func scan() -> ScanReport { GUIExamples.scan }
    func doctor() throws -> DoctorReport {
        doctorReads += 1
        if doctorFails { throw GUIError.unavailable("Manifest could not be read") }
        return GUIExamples.doctor
    }
    func history() -> [HistoryEntry] { [] }
    func caches() -> [PurgeItem] { GUIExamples.caches }
    func updates() -> [UpdateWorkflowRecord] { [] }
    func recovery() -> GUIRecoverySnapshot { GUIRecoverySnapshot(items: []) }
    func previewRecovery(_ item: GUIRecoveryItem) throws -> GUIActionPreview { throw GUIError.unavailable("Not configured") }
    func previewUpdate(_ request: GUIUpdateRequest) throws -> GUIActionPreview { throw GUIError.unavailable("Not configured") }
    func executeAction(_ confirmation: GUIActionConfirmation,
                       progress: @escaping @Sendable (GUIActionProgress) -> Void) throws -> GUIActionResult {
        throw GUIError.unavailable("Not configured")
    }
    func discardAction(_ id: UUID) {}
    func previewApplication(_ app: GUIApplication, volumePath: String?) async throws -> GUIActionPreview {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitForPreview() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func completePreview() {
        pending?.resume(returning: GUIActionPreview(kind: .migration(.move), detail: GUIPreview(title: "Move Preview", subtitle: "", rows: []), confirmTitle: "Move"))
        pending = nil
    }
    func previewCaches(_ items: [PurgeItem]) -> GUIActionPreview { GUIActionPreview(kind: .cleanup, detail: GUIPreview(title: "", subtitle: "", rows: []), confirmTitle: "Clean") }
    func previewXcode(volumePath: String) -> GUIPreview { GUIPreview(title: "", subtitle: "", rows: []) }
}
