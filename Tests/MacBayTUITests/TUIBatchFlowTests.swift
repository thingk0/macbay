import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIBatchFlowTests: XCTestCase {
    private let volume = "/Volumes/SSD"

    private func candidate(_ name: String, _ grade: CompatibilityGrade? = .safe, size: UInt64 = 1_000_000_000) -> AppCandidate {
        let compatibility = grade.map {
            CompatibilityAssessment(grade: $0, reasons: $0 == .safe ? [] : ["\(name) risk"], evidence: [])
        }
        return AppCandidate(name: name, path: "/Applications/\(name)", sizeBytes: size,
                            kind: .application, compatibility: compatibility)
    }

    private func external(_ name: String, _ status: ExternalAppManagementStatus) -> ExternalApplication {
        ExternalApplication(name: name, sourcePath: "/Applications/\(name)",
                            destinationPath: "\(volume)/MacBay/Applications/\(name)",
                            sizeBytes: 1_000_000_000, managementStatus: status)
    }

    private func makeService(candidates: [AppCandidate] = [], externals: [ExternalApplication] = []) -> FakeTUIService {
        let scan = ScanReport(generatedAt: macBayTimestamp(), minimumApplicationSizeBytes: 100,
                              candidates: candidates, externalApplications: externals,
                              unresolvedApplicationLinks: [])
        let ssd = StorageVolume(name: "SSD", path: volume, isInternal: false,
                                totalBytes: 1_000_000_000_000, availableBytes: 500_000_000_000)
        return FakeTUIService(scan: scan, eligibleVolumes: [ssd])
    }

    private func waitIdle(_ app: TUIApp) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !app.state.isLoading && !app.state.isMutating { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("TUI did not become idle")
    }

    private func assertFrame(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.renderString(width: 80, height: 24).components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, file: file, line: line)
        for row in rows {
            let plain = row.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            XCTAssertEqual(plain.count, 80, "Row must be 80 columns: \(plain)", file: file, line: line)
        }
    }

    private func open(_ service: FakeTUIService, restore: Bool = false) -> TUIApp {
        let app = TUIApp(service: service)
        app.loadInitialData()
        waitIdle(app)
        if restore {
            app.handleKey(.down)
            app.handleKey(.down)
        }
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, restore ? .appRestoreList : .appMoveList)
        return app
    }

    private func openPreview(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) -> BatchPreview? {
        app.handleKey(.enter)
        waitIdle(app)
        guard case .batchPreview(let preview) = app.state.currentScreen else {
            XCTFail("Expected batch preview, got \(app.state.currentScreen)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(app.state.confirmFocusIndex, 0, "Cancel must be the default", file: file, line: line)
        assertFrame(app, file: file, line: line)
        return preview
    }

    private func pressConfirmButton(_ app: TUIApp) {
        app.handleKey(.right)
        app.handleKey(.enter)
    }

    private func dockRuns(_ service: FakeTUIService) -> [String] {
        service.dockCalls.filter { !$0.dryRun }.map(\.appName)
    }

    // MARK: - Move

    func testMoveBatchPreviewsConfirmsAndRunsEachSelectedAppInOrder() {
        let service = makeService(candidates: [candidate("A.app", size: 3), candidate("B.app", size: 2), candidate("C.app", size: 1)])
        let app = open(service)
        app.handleKey(.char(" "))
        app.handleKey(.down)
        app.handleKey(.down)
        app.handleKey(.char(" "))
        XCTAssertEqual(app.state.selectedMovePaths, ["/Applications/A.app", "/Applications/C.app"])
        XCTAssertTrue(app.renderString().contains("Batch: 2 apps"))
        assertFrame(app)

        guard let preview = openPreview(app) else { return }
        XCTAssertEqual(preview.included.map(\.appName), ["A.app", "C.app"])
        XCTAssertEqual(preview.volumePath, volume)
        XCTAssertTrue(service.dockCalls.allSatisfy(\.dryRun))
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("Included (2)"))
        XCTAssertTrue(frame.contains("Required: 1.9 GB"))
        XCTAssertTrue(frame.contains("stops at the first failure"))

        pressConfirmButton(app)
        guard case .batchConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        XCTAssertTrue(app.renderString().contains("Confirm & Move 2 App(s)"))
        assertFrame(app)
        XCTAssertTrue(dockRuns(service).isEmpty)

        pressConfirmButton(app)
        waitIdle(app)
        guard case .batchResult(let report) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertTrue(report.allSucceeded)
        XCTAssertEqual(dockRuns(service), ["A.app", "C.app"])
        // Each real run is preceded by its own revalidation dry run.
        XCTAssertEqual(service.dockCalls.suffix(4).map(\.dryRun), [true, false, true, false])
        XCTAssertTrue(service.dockCalls.allSatisfy { $0.volumePath == volume && !$0.force })
        XCTAssertTrue(app.renderString().contains("All 2 application(s) moved"))
        assertFrame(app)

        app.handleKey(.enter)
        waitIdle(app)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertTrue(app.state.selectedMovePaths.isEmpty)
    }

    func testCancelAndEmptySelectionNeverMutate() {
        let service = makeService(candidates: [candidate("A.app"), candidate("B.app")])
        let app = open(service)

        // Without a selection, Enter keeps the single-app flow.
        app.handleKey(.enter)
        waitIdle(app)
        guard case .dryRunPreview(let plan) = app.state.currentScreen else { return XCTFail("Single-app flow must remain") }
        XCTAssertEqual(plan.appName, "A.app")
        app.handleKey(.escape)

        // Clearing a selection also falls back to the single-app flow.
        app.handleKey(.char(" "))
        app.handleKey(.char("x"))
        XCTAssertTrue(app.state.selectedMovePaths.isEmpty)
        app.handleKey(.enter)
        waitIdle(app)
        guard case .dryRunPreview = app.state.currentScreen else { return XCTFail("Expected single preview") }
        app.handleKey(.escape)

        app.handleKey(.char("a"))
        for cancelWithEscape in [false, true] {
            _ = openPreview(app)
            app.handleKey(cancelWithEscape ? .escape : .enter)
            XCTAssertEqual(app.state.currentScreen, .appMoveList)
            _ = openPreview(app)
            pressConfirmButton(app)
            guard case .batchConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
            app.handleKey(cancelWithEscape ? .escape : .enter)
            guard case .batchPreview = app.state.currentScreen else { return XCTFail("Must return to preview") }
            app.handleKey(.escape)
            XCTAssertEqual(app.state.currentScreen, .appMoveList)
        }
        XCTAssertTrue(dockRuns(service).isEmpty)
        XCTAssertEqual(app.state.selectedMovePaths.count, 2, "Cancelling keeps the selection for another try")
    }

    func testSelectionsStayVisibleWhenSearchAndFiltersChange() {
        let service = makeService(candidates: [candidate("Alpha.app"), candidate("Beta.app"), candidate("Risky.app", .popupRisk)])
        let app = open(service)
        app.handleKey(.char(" ")) // Alpha.app, sorted first by equal size then name

        app.handleKey(.char("/"))
        for character in "Beta" { app.handleKey(.char(character)) }
        app.handleKey(.enter)
        XCTAssertEqual(Set(app.state.moveCandidates.map(\.name)), ["Alpha.app", "Beta.app"])
        XCTAssertTrue(app.renderString().contains("1 outside filter"))
        assertFrame(app)

        app.handleKey(.char("c"))
        app.handleKey(.char("f"))
        app.handleKey(.right)
        app.handleKey(.right) // Review
        app.handleKey(.enter)
        XCTAssertEqual(app.state.moveStatusFilter, .review)
        XCTAssertEqual(Set(app.state.moveCandidates.map(\.name)), ["Alpha.app", "Risky.app"])
        XCTAssertTrue(app.renderString().contains("[x]"))

        guard let preview = openPreview(app) else { return }
        XCTAssertEqual(preview.items.map(\.appName), ["Alpha.app"], "Only the visible selection is previewed")
    }

    func testMixedStatusesExcludeBlockedAndRequireRiskAcceptance() {
        let service = makeService(candidates: [
            candidate("Blocked.app", .blocked, size: 5),
            candidate("Busy.app", size: 4),
            candidate("Risky.app", .popupRisk, size: 3),
            candidate("Safe.app", size: 2),
            candidate("Unknown.app", nil, size: 1)
        ])
        service.dockErrorsByApp["Busy.app"] = MacBayError.unsupportedOperation("Busy.app is running")
        let app = open(service)

        app.handleKey(.char(" "))
        XCTAssertTrue(app.state.selectedMovePaths.isEmpty)
        XCTAssertTrue(app.state.errorMessage?.contains("blocked") == true)
        app.handleKey(.char("a"))
        XCTAssertEqual(app.state.selectedMovePaths.count, 4)
        XCTAssertTrue(app.state.errorMessage?.contains("1 blocked") == true)

        guard let preview = openPreview(app) else { return }
        XCTAssertEqual(preview.included.map(\.appName), ["Risky.app", "Safe.app", "Unknown.app"])
        XCTAssertEqual(preview.excluded.map(\.appName), ["Busy.app"])
        XCTAssertEqual(preview.riskItems.map(\.appName), ["Risky.app"])
        var frame = app.renderString(width: 80, height: 60)
        XCTAssertTrue(frame.contains("Busy.app: Busy.app is running"))
        XCTAssertTrue(frame.contains("Risk: Risky.app risk"))
        XCTAssertTrue(frame.contains("Accept Risk for 1 App(s)"))

        pressConfirmButton(app)
        XCTAssertTrue(app.state.batchRiskAccepted)
        guard case .batchPreview = app.state.currentScreen else { return XCTFail("Risk acceptance stays on the preview") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        frame = app.renderString(width: 80, height: 60)
        XCTAssertTrue(frame.contains("Risk accepted (--force) for: Risky.app"))
        assertFrame(app)

        pressConfirmButton(app)
        pressConfirmButton(app)
        waitIdle(app)
        XCTAssertEqual(dockRuns(service), ["Risky.app", "Safe.app", "Unknown.app"])
        let forced = service.dockCalls.filter { !$0.dryRun }.map(\.force)
        XCTAssertEqual(forced, [true, false, false])
        guard case .batchResult(let report) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertTrue(report.allSucceeded)
        XCTAssertTrue(app.renderString(width: 80, height: 40).contains("EXCLUDED Busy.app"))
    }

    func testPartialFailureStopsAndReportsEachApp() {
        let service = makeService(candidates: [candidate("A.app", size: 3), candidate("B.app", size: 2), candidate("C.app", size: 1)])
        service.dockMutateErrorsByApp["B.app"] = MacBayError.unsupportedOperation("Copy failed for B.app")
        let app = open(service)
        app.handleKey(.char("a"))
        _ = openPreview(app)
        pressConfirmButton(app)
        pressConfirmButton(app)
        waitIdle(app)

        guard case .batchResult(let report) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertFalse(report.allSucceeded)
        XCTAssertEqual(report.results.map(\.appName), ["A.app", "B.app", "C.app"])
        XCTAssertEqual([report.succeededCount, report.failedCount, report.notStartedCount], [1, 1, 1])
        XCTAssertFalse(service.dockCalls.contains { $0.appName == "C.app" && !$0.dryRun })
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("stopped after a failure"))
        XCTAssertTrue(frame.contains("Copy failed for B.app"))
        XCTAssertTrue(frame.contains("SKIPPED C.app"))
        XCTAssertFalse(frame.contains("All 3"))
        assertFrame(app)
    }

    func testStalePreviewStopsBeforeAnyChange() {
        let service = makeService(candidates: [candidate("A.app", size: 2), candidate("B.app", size: 1)])
        let app = open(service)
        app.handleKey(.char("a"))
        _ = openPreview(app)
        pressConfirmButton(app)
        service.destinationOverrides["A.app"] = "/Volumes/Other/MacBay/Applications/A.app"
        pressConfirmButton(app)
        waitIdle(app)

        XCTAssertTrue(dockRuns(service).isEmpty)
        guard case .batchResult(let report) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertEqual([report.succeededCount, report.failedCount, report.notStartedCount], [0, 1, 1])
        XCTAssertTrue(app.renderString().contains("changed since the preview"))
    }

    func testRiskEscalationAfterPreviewIsTreatedAsStale() {
        let service = makeService(candidates: [candidate("A.app")])
        let app = open(service)
        app.handleKey(.char(" "))
        _ = openPreview(app)
        pressConfirmButton(app)
        service.compatibilityByApp["A.app"] = CompatibilityAssessment(grade: .popupRisk, reasons: ["New helper"], evidence: [])
        pressConfirmButton(app)
        waitIdle(app)
        XCTAssertTrue(dockRuns(service).isEmpty)
    }

    func testCombinedSizeAboveFreeSpaceCannotContinue() {
        let service = makeService(candidates: [candidate("A.app"), candidate("B.app")])
        service.availableBytesByPath[volume] = 1_500_000_000
        let app = open(service)
        app.handleKey(.char("a"))
        guard let preview = openPreview(app) else { return }
        XCTAssertFalse(preview.canProceed)
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("Not enough space"))
        XCTAssertTrue(frame.contains("Back to List"))
        pressConfirmButton(app)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertTrue(dockRuns(service).isEmpty)
    }

    func testLongPreviewScrollsWithinFrame() {
        let service = makeService(candidates: (0..<12).map { candidate("App\($0).app", size: UInt64(100 - $0)) })
        let app = open(service)
        app.handleKey(.char("a"))
        _ = openPreview(app)
        XCTAssertTrue(app.renderString().contains("[↑/↓] Scroll · lines 1-"))
        for _ in 0..<60 { app.handleKey(.down) }
        XCTAssertGreaterThan(app.state.detailScrollOffset, 0)
        XCTAssertTrue(app.renderString().contains("App11.app"))
        assertFrame(app)
    }

    func testMultipleVolumesAskOnceForTheBatch() {
        let service = makeService(candidates: [candidate("A.app"), candidate("B.app")])
        service.eligibleVolumesToReturn.append(StorageVolume(name: "Other", path: "/Volumes/Other", isInternal: false,
                                                             totalBytes: 1_000_000_000_000, availableBytes: 1_000_000_000))
        let app = open(service)
        app.handleKey(.char("a"))
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .batchVolumeSelect)
        XCTAssertTrue(app.renderString().contains("2 applications"))
        assertFrame(app)
        app.handleKey(.down)
        guard let preview = openPreview(app) else { return }
        XCTAssertEqual(preview.volumePath, "/Volumes/Other")
        XCTAssertEqual(app.state.sessionVolumePath, "/Volumes/Other")
    }

    // MARK: - Restore

    func testRestoreBatchOnlySelectsManagedAppsAndRunsUndock() {
        let service = makeService(externals: [
            external("Managed1.app", .macBay),
            external("Managed2.app", .macBay),
            external("Stray.app", .unmanaged)
        ])
        let app = open(service, restore: true)
        XCTAssertEqual(app.state.restoreItems.map(\.name), ["Managed1.app", "Managed2.app", "Stray.app"])

        app.handleKey(.down)
        app.handleKey(.down)
        app.handleKey(.char(" "))
        XCTAssertTrue(app.state.selectedRestorePaths.isEmpty)
        XCTAssertTrue(app.state.errorMessage?.contains("not managed") == true)
        app.handleKey(.char("a"))
        XCTAssertEqual(app.state.selectedRestorePaths.count, 2)
        XCTAssertTrue(app.renderString().contains("Batch: 2 apps"))
        assertFrame(app)

        guard let preview = openPreview(app) else { return }
        XCTAssertEqual(preview.operation, .undock)
        XCTAssertTrue(app.renderString().contains("Destination: internal /Applications"))
        pressConfirmButton(app)
        pressConfirmButton(app)
        waitIdle(app)
        XCTAssertEqual(service.undockCalls.filter { !$0.dryRun }.map(\.appName), ["Managed1.app", "Managed2.app"])
        XCTAssertTrue(service.undockCalls.allSatisfy { $0.volumePath == nil })
        XCTAssertTrue(app.renderString().contains("All 2 application(s) restored"))
        assertFrame(app)
        app.handleKey(.escape)
        waitIdle(app)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
    }

    func testRestoreFailureStopsRemainingApps() {
        let service = makeService(externals: [external("A.app", .macBay), external("B.app", .macBay)])
        service.undockMutateErrorsByApp["A.app"] = MacBayError.unsupportedOperation("A.app is running")
        let app = open(service, restore: true)
        app.handleKey(.char("a"))
        _ = openPreview(app)
        pressConfirmButton(app)
        pressConfirmButton(app)
        waitIdle(app)
        XCTAssertFalse(service.undockCalls.contains { $0.appName == "B.app" && !$0.dryRun })
        guard case .batchResult(let report) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertEqual([report.succeededCount, report.failedCount, report.notStartedCount], [0, 1, 1])
    }

    func testSelectionDropsAppsThatDisappearOnRescan() {
        let service = makeService(candidates: [candidate("A.app"), candidate("B.app")])
        let app = open(service)
        app.handleKey(.char("a"))
        service.scanToReturn = ScanReport(generatedAt: macBayTimestamp(), minimumApplicationSizeBytes: 100,
                                          candidates: [candidate("B.app")], externalApplications: [],
                                          unresolvedApplicationLinks: [])
        app.handleKey(.char("r"))
        waitIdle(app)
        XCTAssertEqual(app.state.selectedMovePaths, ["/Applications/B.app"])
    }
}
