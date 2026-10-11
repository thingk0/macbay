import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIPurgeFlowTests: XCTestCase {
    private func item(_ app: String = "Example", _ cache: String = "Code Cache", bytes: UInt64 = 1024, running: Bool = false) -> PurgeItem {
        PurgeItem(appName: app, path: "/sandbox/Library/Application Support/\(app)/\(cache)",
                  category: .chromiumCache, sizeBytes: bytes, isRunning: running)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition())
    }

    private func open(_ service: FakeTUIService) -> TUIApp {
        let app = TUIApp(service: service)
        for _ in 0..<4 { app.handleKey(.down) }
        app.handleKey(.enter)
        waitUntil { !app.state.purgeLoading }
        XCTAssertEqual(app.state.currentScreen, .purgeList)
        assertFrame(app)
        return app
    }

    private func assertFrame(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.renderString(width: 80, height: 24)
        let rows = frame.components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, file: file, line: line)
        for row in rows {
            let plain = row.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            XCTAssertEqual(plain.count, 80, file: file, line: line)
        }
    }

    private func preview(_ app: TUIApp) {
        app.handleKey(.char("a"))
        app.handleKey(.enter)
        guard case .purgePreview = app.state.currentScreen else { return XCTFail("Missing preview") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        assertFrame(app)
    }

    private func confirmation(_ app: TUIApp) {
        app.handleKey(.right)
        app.handleKey(.enter)
        guard case .purgeConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        XCTAssertTrue(app.renderString().contains("Confirm & Purge"))
        assertFrame(app)
    }

    func testGroupAndIndividualSelectionExcludeRunningTargets() {
        let service = FakeTUIService()
        let first = item(bytes: 3000)
        let second = item("Example", "GPUCache", bytes: 2000)
        let running = item("Running", bytes: 1000, running: true)
        service.purgeItemsToReturn = [first, second, running]
        let app = open(service)
        XCTAssertTrue(app.state.selectedPurgeIDs.isEmpty)
        app.handleKey(.char(" ")) // Application group selects both targets.
        XCTAssertEqual(Set(app.state.selectedPurgeItems.map(\.id)), Set([first.id, second.id]))
        app.handleKey(.down)
        app.handleKey(.char(" ")) // Deselect just one cache.
        XCTAssertEqual(app.state.selectedPurgeItems, [second])
        app.handleKey(.char("a"))
        XCTAssertEqual(app.state.selectedPurgeItems.count, 2)
        app.handleKey(.down)
        app.handleKey(.down) // Running app's group.
        app.handleKey(.char(" "))
        app.handleKey(.down) // Running cache itself.
        app.handleKey(.char(" "))
        XCTAssertFalse(app.state.selectedPurgeIDs.contains(running.id))
        XCTAssertTrue(app.renderString().contains("Skipped: running"))
        app.handleKey(.char("c"))
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .purgeList)
        XCTAssertTrue(service.purgeExecutions.isEmpty)
    }

    func testPreviewAndSeparateConfirmationCancelByDefault() {
        for cancelWithEscape in [false, true] {
            let service = FakeTUIService()
            service.purgeItemsToReturn = [item()]
            let app = open(service)
            preview(app)
            XCTAssertTrue(service.purgeExecutions.isEmpty)
            app.handleKey(cancelWithEscape ? .escape : .enter)
            XCTAssertEqual(app.state.currentScreen, .purgeList)
            preview(app)
            confirmation(app)
            XCTAssertTrue(service.purgeExecutions.isEmpty)
            app.handleKey(cancelWithEscape ? .escape : .enter)
            guard case .purgePreview = app.state.currentScreen else { return XCTFail("Cancel must return to preview") }
            XCTAssertTrue(service.purgeExecutions.isEmpty)
            app.handleKey(.escape)
            app.handleKey(.escape)
            XCTAssertEqual(app.state.currentScreen, .home)
        }
    }

    func testOnlySelectedTargetExecutesAndHomeActionsRemainVisible() {
        let volumes = (0..<4).map {
            StorageVolume(name: "Drive-\($0)", path: "/Volumes/Drive-\($0)", isInternal: false,
                          totalBytes: 100_000, availableBytes: 50_000)
        }
        let service = FakeTUIService(eligibleVolumes: volumes)
        let selected = item(bytes: 3000)
        service.purgeItemsToReturn = [selected, item("Example", "GPUCache", bytes: 2000)]
        let app = open(service)
        app.handleKey(.down)
        app.handleKey(.char(" "))
        app.handleKey(.enter)
        guard case .purgePreview(let value) = app.state.currentScreen else { return XCTFail("Missing preview") }
        XCTAssertEqual(value.items, [selected])
        confirmation(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertEqual(service.purgeExecutions, [[selected]])
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        app.handleKey(.escape)
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("Cache Cleanup"))
        XCTAssertTrue(frame.contains("Quit"))
        assertFrame(app)
    }

    func testEmptyAndRunningOnlyScansCannotExecute() {
        for items in [[], [item(running: true)]] {
            let service = FakeTUIService()
            service.purgeItemsToReturn = items
            let app = open(service)
            for key in [Key.up, .down, .char(" "), .char("a"), .enter] { app.handleKey(key) }
            XCTAssertEqual(app.state.currentScreen, .purgeList)
            XCTAssertTrue(app.state.selectedPurgeItems.isEmpty)
            XCTAssertTrue(service.purgeExecutions.isEmpty)
            XCTAssertTrue(app.renderString().contains(items.isEmpty ? "No purgeable caches" : "running applications"))
        }
    }

    func testPartialFailureShowsBytesSkippedAndScrollableFailureDetails() {
        let service = FakeTUIService()
        let good = item("Good", bytes: 4096)
        let bad = item("Bad", bytes: 1024)
        let running = item("Running", running: true)
        service.purgeItemsToReturn = [good, bad, running]
        let failures = (0..<12).map {
            PurgeFailure(appName: "Bad", path: bad.path + "/locked-\($0)", reason: "Permission denied for target \($0)")
        }
        service.purgeReportToReturn = PurgeReport(dryRun: false, purgedItems: [good], failedItems: failures, totalReclaimedBytes: 4096)
        let app = open(service)
        preview(app)
        confirmation(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating }
        guard case .purgeResult(let report, nil) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertEqual(service.purgeExecutions.count, 1)
        XCTAssertEqual(Set(service.purgeExecutions[0].map(\.id)), Set([good.id, bad.id]))
        XCTAssertEqual(report?.skippedItems, [running])
        XCTAssertEqual(report?.totalReclaimedBytes, 4096)
        XCTAssertTrue(app.renderString().contains("Reclaimed: 4.0 KB"))
        XCTAssertTrue(app.renderString().contains("Skipped: 1"))
        assertFrame(app)
        for _ in 0..<100 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Permission denied for target 11"))
        XCTAssertTrue(app.renderString().contains("Return to cache list"))
        assertFrame(app)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .purgeList)
        XCTAssertTrue(app.state.selectedPurgeIDs.isEmpty)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
    }

    func testRefreshDropsSelectionsForTargetsThatStartRunning() {
        let service = FakeTUIService()
        service.purgeItemsToReturn = [item()]
        let app = open(service)
        app.handleKey(.char("a"))
        service.purgeItemsToReturn = [item(running: true)]
        app.handleKey(.char("r"))
        waitUntil { !app.state.purgeLoading }
        XCTAssertTrue(app.state.selectedPurgeIDs.isEmpty)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .purgeList)
        XCTAssertTrue(service.purgeExecutions.isEmpty)
    }

    func testLoadingAndFailedScanBlockSelectionAndCanRetry() {
        let service = FakeTUIService()
        service.artificialDelay = 0.1
        service.purgeItemsToReturn = [item()]
        let app = TUIApp(service: service)
        for _ in 0..<4 { app.handleKey(.down) }
        app.handleKey(.enter)
        XCTAssertTrue(app.state.purgeLoading)
        app.handleKey(.char("a"))
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .purgeList)
        waitUntil { !app.state.purgeLoading }
        app.handleKey(.char("a"))
        service.purgeScanError = MacBayError.unsupportedOperation("Scan failed")
        app.handleKey(.char("r"))
        waitUntil { !app.state.purgeLoading }
        XCTAssertFalse(app.state.purgeLoaded)
        XCTAssertTrue(app.state.selectedPurgeIDs.isEmpty)
        app.handleKey(.enter)
        XCTAssertTrue(app.renderString().contains("Scan failed"))
        service.purgeScanError = nil
        app.handleKey(.char("r"))
        waitUntil { !app.state.purgeLoading }
        XCTAssertTrue(app.state.purgeLoaded)
        XCTAssertTrue(service.purgeExecutions.isEmpty)
    }

    func testLongListsAndPreviewKeepButtonsVisibleAtMinimumSize() {
        let service = FakeTUIService()
        service.purgeItemsToReturn = (0..<30).map { item("App-\($0)", bytes: UInt64(1000 + $0)) }
        let app = open(service)
        for _ in 0..<100 { app.handleKey(.down) }
        XCTAssertEqual(app.state.purgeListIndex, app.state.purgeRows.count - 1)
        assertFrame(app)
        preview(app)
        for _ in 0..<150 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Continue to Confirmation"))
        assertFrame(app)
        confirmation(app)
        for _ in 0..<150 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Confirm & Purge"))
        XCTAssertTrue(service.purgeExecutions.isEmpty)
        assertFrame(app)
    }

    func testExecutionErrorAndDeferredQuit() {
        let service = FakeTUIService()
        service.purgeItemsToReturn = [item()]
        service.purgeExecutionError = MacBayError.unsupportedOperation("Purge failed")
        let app = open(service)
        preview(app)
        confirmation(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating }
        XCTAssertTrue(app.renderString().contains("Purge failed"))
        assertFrame(app)

        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        preview(app)
        confirmation(app)
        service.artificialDelay = 0.15
        app.handleKey(.right)
        app.handleKey(.enter)
        app.handleKey(.ctrlC)
        XCTAssertTrue(app.state.quitDeferred)
        XCTAssertFalse(app.shouldExit)
        app.handleKey(.enter) // Cannot submit a second mutation.
        waitUntil { app.shouldExit }
        XCTAssertEqual(service.purgeExecutions.count, 2)
    }
}
