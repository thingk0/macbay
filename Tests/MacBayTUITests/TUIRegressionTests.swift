import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIRegressionTests: XCTestCase {

    // MARK: - Fixtures

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private enum AnsiState {
        case text
        case escape
        case controlSequence
    }

    private func visibleWidth(_ line: String) -> Int {
        var width = 0
        var state = AnsiState.text

        for character in line {
            guard let scalar = character.unicodeScalars.first else { continue }
            switch state {
            case .text:
                if scalar.value == 0x1B {
                    state = .escape
                } else {
                    width += 1
                }
            case .escape:
                if scalar.value == 0x5B || scalar.value == 0x4F {
                    state = .controlSequence
                } else {
                    state = .text
                }
            case .controlSequence:
                if scalar.value >= 0x40, scalar.value <= 0x7E {
                    state = .text
                }
            }
        }
        return width
    }

    private func makeVolume(name: String = "SSD", path: String = "/Volumes/SSD") -> StorageVolume {
        StorageVolume(
            name: name,
            path: path,
            isInternal: false,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000
        )
    }

    private func makeSafeCandidate(name: String = "TestApp.app", size: UInt64 = 500_000_000) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: size,
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .safe)
        )
    }

    private func makeRiskCandidate(name: String = "RiskApp.app", reasonCount: Int = 40) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: 600_000_000,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .popupRisk,
                reasons: (0..<reasonCount).map { "Risk factor \($0): requires elevated permissions to install helper tooling" },
                evidence: (0..<reasonCount).map { "SMPrivilegedExecutables[\($0)]" }
            )
        )
    }

    private func makeScan(candidates: [AppCandidate]) -> ScanReport {
        ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: candidates,
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
    }

    // MARK: - Async completion redraws

    func testAsyncCompletionRequestsRedrawWithoutKeyInput() {
        let fake = FakeTUIService()
        fake.artificialDelay = 0.15
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(app.state.isLoading)
        XCTAssertTrue(app.consumeRedrawRequest(), "Starting a load must repaint the loading indicator")

        XCTAssertTrue(waitUntil { !app.state.isLoading }, "Scan should finish")
        XCTAssertTrue(app.state.scanLoaded)
        XCTAssertTrue(app.consumeRedrawRequest(), "Async completion must request a redraw without key input")
    }

    // MARK: - Request queueing

    func testLoadRequestsAreQueuedInsteadOfDropped() {
        let fake = FakeTUIService()
        fake.artificialDelay = 0.1
        let app = TUIApp(service: fake)

        app.loadStatus()
        app.loadScan()
        XCTAssertTrue(app.state.isLoading)

        XCTAssertTrue(waitUntil { !app.state.isLoading })
        XCTAssertEqual(fake.statusCalls, 1)
        XCTAssertEqual(fake.scanCalls, 1, "Scan requested during another load must still run")
        XCTAssertTrue(app.state.statusLoaded)
        XCTAssertTrue(app.state.scanLoaded)
    }

    func testInitialLoadCompletesEverySection() {
        let fake = FakeTUIService()
        let app = TUIApp(service: fake)

        app.loadInitialData()
        XCTAssertTrue(waitUntil { !app.state.isLoading })

        XCTAssertEqual(fake.statusCalls, 1)
        XCTAssertEqual(fake.scanCalls, 1)
        XCTAssertEqual(fake.doctorCalls, 1)
        XCTAssertTrue(app.state.statusLoaded)
        XCTAssertTrue(app.state.scanLoaded)
        XCTAssertTrue(app.state.doctorLoaded)
    }

    // MARK: - Confirm screens with long content

    func testLongRiskContentKeepsAcceptButtonVisible() {
        let candidate = makeRiskCandidate(reasonCount: 40)
        let fake = FakeTUIService(scan: makeScan(candidates: [candidate]), eligibleVolumes: [makeVolume()])
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })
        app.handleKey(.enter)
        app.handleKey(.enter)

        guard case .riskReview = app.state.currentScreen else {
            return XCTFail("Expected riskReview, got \(app.state.currentScreen)")
        }

        let initial = app.renderString(width: 80, height: 24)
        XCTAssertTrue(initial.contains("[ Accept Risk & Proceed ]"), "Accept button must stay visible on long content")
        XCTAssertTrue(initial.contains("Scroll · lines"), "Overflowing body must advertise scrolling")

        // Rows: 0-2 header, 3-21 content, 22 status line, 23 key help.
        let rows = initial.components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24)
        XCTAssertTrue(rows[20].contains("Scroll · lines"), "Scroll indicator sits above the pinned buttons")
        XCTAssertTrue(rows[21].contains("[ Accept Risk & Proceed ]"), "Buttons must stay pinned to the bottom of the content area")
        XCTAssertTrue(rows[22].contains("─"), "Status line must remain visible below the buttons")

        app.handleKey(.down)
        app.handleKey(.down)
        let scrolled = app.renderString(width: 80, height: 24)
        XCTAssertTrue(scrolled.contains("[ Accept Risk & Proceed ]"), "Buttons stay pinned while the body scrolls")
        XCTAssertNotEqual(initial, scrolled, "Scrolling must move the body")
    }

    func testDetailScrollClampsToContentLength() {
        let candidate = makeRiskCandidate(reasonCount: 40)
        let fake = FakeTUIService(scan: makeScan(candidates: [candidate]), eligibleVolumes: [makeVolume()])
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })
        app.handleKey(.enter)
        app.handleKey(.enter)

        guard let metrics = TerminalRenderer().scrollableDetailMetrics(state: app.state, width: 80, height: 24) else {
            return XCTFail("riskReview should expose scroll metrics")
        }
        XCTAssertGreaterThan(metrics.total, metrics.viewport, "Fixture must overflow the viewport")

        for _ in 0..<200 {
            app.handleKey(.down)
        }
        XCTAssertEqual(app.state.detailScrollOffset, metrics.total - metrics.viewport)

        for _ in 0..<200 {
            app.handleKey(.up)
        }
        XCTAssertEqual(app.state.detailScrollOffset, 0)
    }

    func testRenderedFrameKeepsFixedLineWidths() {
        let longName = String(repeating: "VeryLongApplicationName", count: 6) + ".app"
        let candidate = AppCandidate(
            name: longName,
            path: "/Applications/\(longName)/Contents/Resources/Nested/Deeply/Inside/The/Bundle",
            sizeBytes: 900_000_000,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .popupRisk,
                reasons: [String(repeating: "long reason ", count: 20)],
                evidence: [String(repeating: "long evidence ", count: 20)]
            )
        )
        let fake = FakeTUIService(scan: makeScan(candidates: [candidate]), eligibleVolumes: [makeVolume()])
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })
        app.handleKey(.enter)
        app.handleKey(.enter)

        let lines = app.renderString(width: 80, height: 24).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 24, "Frame must keep exactly 24 rows")
        for line in lines {
            XCTAssertEqual(visibleWidth(line), 80, "Every row must be exactly 80 columns: \(line)")
        }
    }

    // MARK: - List scrolling

    func testMoveNavigationKeepsChromeAndDetailAtFixedRows() {
        for count in [3, 30] {
            let candidates = (0..<count).map { makeSafeCandidate(name: "앱\($0).app") }
            let app = TUIApp(service: FakeTUIService(scan: makeScan(candidates: candidates)))
            app.loadScan()
            XCTAssertTrue(waitUntil { app.state.scanLoaded })
            app.handleKey(.enter)

            let initial = app.renderString(width: 80, height: 24).components(separatedBy: "\r\n")
            let detailRow = 3 + 6 + TerminalRenderer().listVisibleRows(for: .appMoveList, terminalHeight: 24) + 2
            for key in Array(repeating: Key.down, count: 35) + Array(repeating: Key.up, count: 35) {
                app.handleKey(key)
                let frame = app.renderString(width: 80, height: 24)
                let rows = frame.components(separatedBy: "\r\n")
                XCTAssertEqual(rows.count, 24)
                for row in [0, 1, 2, 3, 4, 22, 23] {
                    XCTAssertEqual(rows[row], initial[row])
                }
                XCTAssertTrue(rows[detailRow].contains("Selected:"))
                let output = TerminalController.frameOutput(frame)
                XCTAssertFalse(output.contains("\n"), "Painting must not scroll at the bottom margin")
                XCTAssertFalse(output.contains("\r"))
                for row in 1...24 {
                    XCTAssertTrue(output.contains("\u{001B}[\(row);1H"))
                }
                XCTAssertTrue(output.hasPrefix("\u{001B}[?7l"))
                XCTAssertTrue(output.hasSuffix("\u{001B}[H\u{001B}[?7h"))
            }
        }
    }

    func testFrameOutputContainsEmbeddedLineBreaksWithinTheirRow() {
        let output = TerminalController.frameOutput("Name\nwith\rcontrols\t.app\r\nFooter")
        XCTAssertTrue(output.contains("Name with controls .app"))
        XCTAssertTrue(output.contains("\u{001B}[2;1H\u{001B}[0m\u{001B}[2KFooter"))
        XCTAssertFalse(output.contains("\n"))
        XCTAssertFalse(output.contains("\r"))
    }

    func testListSelectionStaysWithinRenderedRows() {
        let candidates = (0..<30).map { index in
            makeSafeCandidate(name: String(format: "App%03d.app", index), size: UInt64(1_000_000_000 - index))
        }
        let fake = FakeTUIService(scan: makeScan(candidates: candidates), eligibleVolumes: [makeVolume()])
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })
        app.handleKey(.enter)

        for _ in 0..<15 {
            app.handleKey(.down)
        }
        XCTAssertEqual(app.state.moveListIndex, 15)

        let capacity = TerminalRenderer().listVisibleRows(for: .appMoveList, terminalHeight: 24)
        XCTAssertLessThan(
            app.state.moveListIndex,
            app.state.moveListScrollOffset + capacity,
            "Selected row must stay inside the rendered window"
        )

        let output = app.renderString(width: 80, height: 24)
        XCTAssertTrue(output.contains("App015.app"), "Selected app must be rendered")
        XCTAssertFalse(output.contains("App000.app"), "First app should have scrolled out of view")
    }

    // MARK: - Failure reporting

    func testMigrationFailureShowsErrorDetailsAndDoctorGuidance() {
        let fake = FakeTUIService(scan: makeScan(candidates: [makeSafeCandidate()]), eligibleVolumes: [makeVolume()])
        fake.shouldThrowDockOnMutate = MacBayError.manifestFailed(
            path: "/Users/test/.macbay/manifest.json",
            details: "record write failed"
        )
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })

        app.handleKey(.enter)
        app.handleKey(.enter)
        XCTAssertTrue(waitUntil {
            if case .dryRunPreview = app.state.currentScreen { return true }
            return false
        }, "Dry-run preview should be prepared")

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil {
            if case .operationResult = app.state.currentScreen { return true }
            return false
        }, "Failure screen should appear")

        XCTAssertFalse(app.state.isMutating)
        XCTAssertTrue(app.consumeRedrawRequest(), "Failure must request a redraw without key input")

        let output = app.renderString(width: 80, height: 24)
        XCTAssertTrue(output.contains("record write failed"), "Failure screen must show the error details")
        XCTAssertTrue(output.contains("mb doctor"), "Failure screen must point at mb doctor")
        XCTAssertFalse(output.contains("No files were harmed"), "Failure screen must not promise untouched data")
    }
}
