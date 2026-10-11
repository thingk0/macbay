import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIVolumeRefreshTests: XCTestCase {
    private func volume(_ name: String, _ path: String? = nil, free: UInt64 = 500_000_000_000) -> StorageVolume {
        StorageVolume(name: name, path: path ?? "/Volumes/\(name)", isInternal: false,
                      totalBytes: 1_000_000_000_000, availableBytes: free)
    }

    private func candidate(_ name: String) -> AppCandidate {
        AppCandidate(name: name, path: "/Applications/\(name)", sizeBytes: 1_000_000_000,
                     kind: .application, compatibility: CompatibilityAssessment(grade: .safe))
    }

    private func makeService(volumes: [StorageVolume], externals: [ExternalApplication] = []) -> FakeTUIService {
        let scan = ScanReport(generatedAt: macBayTimestamp(), minimumApplicationSizeBytes: 100,
                              candidates: [candidate("A.app"), candidate("B.app")],
                              externalApplications: externals, unresolvedApplicationLinks: [])
        return FakeTUIService(scan: scan, eligibleVolumes: volumes)
    }

    private func waitIdle(_ app: TUIApp) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !app.state.isLoading && !app.state.isMutating { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("TUI did not become idle")
    }

    private func start(_ service: FakeTUIService) -> TUIApp {
        let app = TUIApp(service: service)
        app.loadInitialData()
        waitIdle(app)
        return app
    }

    /// Delivers one notification and waits for the check and any refresh it started.
    private func notify(_ app: TUIApp, times: Int = 1) {
        for _ in 0..<times { app.applyVolumeChangeEvent() }
        app.waitForVolumeChecks()
        waitIdle(app)
    }

    private func plain(_ app: TUIApp) -> String {
        app.renderString().replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func assertFrame(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) {
        let rows = plain(app).components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.count, 80, "Row must be 80 columns: \(row)", file: file, line: line)
        }
    }

    private func openDockPreview(_ app: TUIApp) {
        app.handleKey(.enter) // Move Application
        app.handleKey(.enter) // A.app
        waitIdle(app)
        guard case .dryRunPreview = app.state.currentScreen else { return XCTFail("Missing dock preview") }
    }

    private func mutations(_ service: FakeTUIService) -> Int {
        service.dockCalls.filter { !$0.dryRun }.count + service.undockCalls.filter { !$0.dryRun }.count
            + service.moveCalls.filter { !$0.dryRun }.count + service.adoptExecuteCalls.count
    }

    // MARK: - Connect and disconnect

    func testConnectUpdatesListAvailabilityWithoutManualRefresh() {
        let service = makeService(volumes: [])
        let app = start(service)
        app.handleKey(.enter)
        XCTAssertTrue(plain(app).contains("No external APFS volume connected"))
        let statusCalls = service.statusCalls
        let scanCalls = service.scanCalls

        service.eligibleVolumesToReturn = [volume("SSD")]
        notify(app)

        XCTAssertEqual(app.state.eligibleVolumesList.map(\.path), ["/Volumes/SSD"])
        XCTAssertEqual(service.statusCalls, statusCalls + 1)
        XCTAssertEqual(service.scanCalls, scanCalls, "No app link points into the new volume")
        let frame = plain(app)
        XCTAssertTrue(frame.contains("Destination: SSD at /Volumes/SSD"))
        XCTAssertTrue(frame.contains("Connected: SSD (/Volumes/SSD)."))
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertEqual(mutations(service), 0)
        assertFrame(app)

        app.handleKey(.down)
        XCTAssertNil(app.state.volumeNotice, "The notice clears on the next key press")
    }

    func testDisconnectInvalidatesOpenPreviewAndRequiresNewSelection() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        openDockPreview(app)
        XCTAssertEqual(app.state.sessionVolumePath, "/Volumes/SSD")
        app.handleKey(.right) // Focus Confirm; disconnection must not leave it armed.

        service.eligibleVolumesToReturn = []
        notify(app)

        guard case .infoModal(let title, let message, _) = app.state.currentScreen else {
            return XCTFail("Expected invalidation notice, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(title, "Volume Disconnected")
        XCTAssertTrue(message.contains("nothing was changed"))
        XCTAssertNil(app.state.sessionVolumePath)
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        XCTAssertEqual(app.state.navigationStack.last, .appMoveList)
        XCTAssertTrue(plain(app).contains("Disconnected: SSD (/Volumes/SSD). Choose a destination again."))
        assertFrame(app)

        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertTrue(plain(app).contains("No external APFS volume connected"))
        XCTAssertEqual(mutations(service), 0)
    }

    func testRenamedMountPathInvalidatesBatchPreview() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        app.handleKey(.enter)
        app.handleKey(.char("a"))
        app.handleKey(.enter)
        waitIdle(app)
        guard case .batchPreview = app.state.currentScreen else { return XCTFail("Missing batch preview") }
        app.handleKey(.right)
        app.handleKey(.enter)
        guard case .batchConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }

        service.eligibleVolumesToReturn = [volume("SSD", "/Volumes/SSD 1")]
        notify(app)

        guard case .infoModal = app.state.currentScreen else { return XCTFail("Batch screens must close") }
        XCTAssertEqual(app.state.navigationStack.last, .appMoveList)
        XCTAssertNil(app.state.sessionVolumePath)
        XCTAssertFalse(app.state.batchRiskAccepted)
        XCTAssertTrue(app.state.volumeNotice?.contains("now mounted at /Volumes/SSD 1") == true)
        assertFrame(app)
        XCTAssertEqual(mutations(service), 0)
    }

    func testRestorePreviewOnDisconnectedVolumeIsInvalidatedAndListRescanned() {
        let external = ExternalApplication(name: "Managed.app", sourcePath: "/Applications/Managed.app",
                                           destinationPath: "/Volumes/External/MacBay/Applications/Managed.app",
                                           sizeBytes: 1_000_000_000, managementStatus: .macBay)
        // The fake's restore dry run reports its source under /Volumes/External, like a real link target.
        let service = makeService(volumes: [volume("External")], externals: [external])
        let app = start(service)
        app.handleKey(.down)
        app.handleKey(.down)
        app.handleKey(.enter)
        app.handleKey(.enter)
        waitIdle(app)
        guard case .dryRunPreview(let plan) = app.state.currentScreen else { return XCTFail("Missing restore preview") }
        XCTAssertNil(plan.volumePath, "Restore resolves the volume from the link, as before")
        let scanCalls = service.scanCalls

        service.eligibleVolumesToReturn = []
        notify(app)

        guard case .infoModal = app.state.currentScreen else { return XCTFail("Restore preview must close") }
        XCTAssertEqual(app.state.navigationStack.last, .appRestoreList)
        XCTAssertEqual(service.scanCalls, scanCalls + 1, "Restore entries link into the removed volume")
        XCTAssertEqual(mutations(service), 0)
    }

    func testUnrelatedVolumeChangeKeepsPreview() {
        let service = makeService(volumes: [volume("SSD"), volume("Other")])
        service.defaultVolumeToReturn = DefaultVolume(path: "/Volumes/SSD", name: "SSD", savedAt: "")
        let app = start(service)
        openDockPreview(app)
        let preview = app.state.currentScreen

        service.eligibleVolumesToReturn = [volume("SSD")]
        notify(app)

        XCTAssertEqual(app.state.currentScreen, preview)
        XCTAssertTrue(app.state.volumeNotice?.contains("Disconnected: Other") == true)
    }

    func testXcodeDestinationDisappearanceClearsSelectionAndPreview() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        for _ in 0..<5 { app.handleKey(.down) }
        app.handleKey(.enter)
        waitIdle(app)
        XCTAssertEqual(app.state.xcodeVolumePath, "/Volumes/SSD")
        app.handleKey(.enter)
        waitIdle(app)
        guard case .xcodePreview = app.state.currentScreen else { return XCTFail("Missing Xcode preview") }

        service.eligibleVolumesToReturn = []
        notify(app)

        guard case .infoModal = app.state.currentScreen else { return XCTFail("Xcode preview must close") }
        XCTAssertNil(app.state.xcodeVolumePath)
        XCTAssertTrue(app.state.xcodeVolumes.isEmpty)
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
    }

    // MARK: - Duplicate events

    func testRepeatedEventsWithoutChangesDoNothing() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        app.handleKey(.enter)
        _ = app.consumeRedrawRequest()
        let statusCalls = service.statusCalls

        // Free space drifts constantly; it is not a volume change.
        service.eligibleVolumesToReturn = [volume("SSD", free: 1)]
        notify(app, times: 50)

        XCTAssertEqual(service.statusCalls, statusCalls)
        XCTAssertNil(app.state.volumeNotice)
        XCTAssertFalse(app.consumeRedrawRequest(), "Unchanged volumes must not redraw")
    }

    func testBurstOfEventsAfterOneChangeRefreshesOnce() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        let statusCalls = service.statusCalls
        service.eligibleVolumesToReturn = []
        notify(app, times: 20)
        notify(app, times: 20)
        XCTAssertEqual(service.statusCalls, statusCalls + 1)
    }

    func testEventsBeforeFirstStatusLoadAreIgnored() {
        let service = makeService(volumes: [volume("SSD")])
        let app = TUIApp(service: service)
        notify(app)
        XCTAssertEqual(service.statusCalls, 0)
        XCTAssertNil(app.state.volumeNotice)
    }

    // MARK: - During an operation

    func testDisconnectDuringOperationWarnsAndRefreshesAfterItStops() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        openDockPreview(app)
        service.artificialDelay = 0.4
        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertTrue(app.state.isMutating)
        let statusCalls = service.statusCalls

        service.eligibleVolumesToReturn = []
        app.applyVolumeChangeEvent()
        app.waitForVolumeChecks()

        guard case .mutatingProgress = app.state.currentScreen else { return XCTFail("Operation screen must stay") }
        XCTAssertEqual(service.statusCalls, statusCalls, "No refresh while the operation runs")
        XCTAssertFalse(app.state.deferredVolumeChanges.isEmpty)
        let frame = plain(app)
        XCTAssertTrue(frame.contains("[!] Disconnected: SSD (/Volumes/SSD)."))
        XCTAssertTrue(frame.contains("status refreshes after it stops"))
        assertFrame(app)
        app.handleKey(.char("x"))
        XCTAssertNotNil(app.state.volumeNotice, "Keys during the operation keep the warning")

        service.artificialDelay = 0
        waitIdle(app)
        guard case .operationResult = app.state.currentScreen else { return XCTFail("Missing result") }
        app.handleKey(.enter)
        waitIdle(app)
        XCTAssertTrue(app.state.deferredVolumeChanges.isEmpty)
        XCTAssertGreaterThan(service.statusCalls, statusCalls)
        XCTAssertEqual(app.state.eligibleVolumesList, [])
        XCTAssertEqual(service.dockCalls.filter { !$0.dryRun }.count, 1, "Only the confirmed operation ran")
    }

    func testDoctorIsMarkedStaleAndReloadedWhenOpen() {
        let service = makeService(volumes: [volume("SSD")])
        let app = start(service)
        service.eligibleVolumesToReturn = []
        notify(app)
        XCTAssertFalse(app.state.doctorLoaded)

        for _ in 0..<3 { app.handleKey(.down) }
        app.handleKey(.enter)
        waitIdle(app)
        let doctorCalls = service.doctorCalls
        service.eligibleVolumesToReturn = [volume("SSD")]
        notify(app)
        XCTAssertEqual(service.doctorCalls, doctorCalls + 1)
    }
}
