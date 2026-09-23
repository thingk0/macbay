import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIFilterTests: XCTestCase {
    private func candidate(_ name: String, _ size: UInt64, _ grade: CompatibilityGrade?) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: size,
            kind: .application,
            compatibility: grade.map { CompatibilityAssessment(grade: $0) }
        )
    }

    private func wait(_ app: TUIApp) {
        let deadline = Date().addingTimeInterval(3)
        while app.state.isLoading, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(app.state.isLoading)
    }

    func testMoveFilterCombinesNameStatusAndSize() {
        let oneGB = UInt64(1024 * 1024 * 1024)
        let scan = ScanReport(
            generatedAt: "",
            minimumApplicationSizeBytes: 0,
            candidates: [
                candidate("SafeLarge.app", oneGB * 6, .safe),
                candidate("SafeSmall.app", oneGB, .safe),
                candidate("ReviewLarge.app", oneGB * 8, .popupRisk),
                candidate("UnknownLarge.app", oneGB * 12, nil)
            ]
        )
        let app = TUIApp(service: FakeTUIService(scan: scan))
        app.loadScan()
        wait(app)
        app.handleKey(.enter)
        app.handleKey(.char("/"))
        for character in "Large" { app.handleKey(.char(character)) }
        app.handleKey(.enter)
        app.handleKey(.char("f"))

        XCTAssertEqual(app.state.currentScreen, .appFilter(restoring: false))
        app.handleKey(.right) // status: All -> Safe
        app.handleKey(.right) // status: Safe -> Review
        app.handleKey(.down)  // size row
        app.handleKey(.right) // All -> >= 1 GB
        app.handleKey(.right) // >= 1 GB -> >= 5 GB
        app.handleKey(.enter)

        XCTAssertEqual(app.state.moveStatusFilter, .review)
        XCTAssertEqual(app.state.moveSizeFilter, .atLeast5GB)
        XCTAssertEqual(app.state.moveCandidates.map(\.name), ["ReviewLarge.app"])
        XCTAssertEqual(app.state.moveListIndex, 0)
    }

    func testFilterEscapeDoesNotApplyDraftValues() {
        let app = TUIApp(service: FakeTUIService(scan: ScanReport(generatedAt: "", minimumApplicationSizeBytes: 0, candidates: [candidate("Example.app", 1, .safe)])))
        app.loadScan()
        wait(app)
        app.handleKey(.enter)
        app.handleKey(.char("f"))
        app.handleKey(.right)
        app.handleKey(.down)
        app.handleKey(.right)
        app.handleKey(.escape)

        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertEqual(app.state.moveStatusFilter, .all)
        XCTAssertEqual(app.state.moveSizeFilter, .all)
        XCTAssertEqual(app.state.moveFilterStatusDraft, .all)
        XCTAssertEqual(app.state.moveFilterSizeDraft, .all)
        XCTAssertEqual(app.state.moveCandidates.count, 1)
    }

    func testMoveAndRestoreFiltersAreIndependent() {
        let oneGB = UInt64(1024 * 1024 * 1024)
        let scan = ScanReport(
            generatedAt: "",
            minimumApplicationSizeBytes: 0,
            candidates: [candidate("Move.app", oneGB * 2, .safe)],
            externalApplications: [
                ExternalApplication(
                    name: "Restore.app",
                    sourcePath: "/Applications/Restore.app",
                    destinationPath: "/Volumes/SSD/Restore.app",
                    sizeBytes: oneGB * 2,
                    managementStatus: .macBay
                )
            ]
        )
        let service = FakeTUIService(scan: scan)
        service.statusToReturn = StatusReport(
            generatedAt: "",
            internalVolume: service.statusToReturn.internalVolume,
            externalVolumes: [],
            dockedItems: []
        )
        let app = TUIApp(service: service)
        app.loadInitialData()
        wait(app)

        app.handleKey(.enter) // move
        app.handleKey(.char("f"))
        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.moveStatusFilter, .safe)
        app.handleKey(.escape)

        app.handleKey(.down)
        app.handleKey(.down)
        app.handleKey(.enter) // restore
        app.handleKey(.char("f"))
        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.restoreStatusFilter, .managed)
        XCTAssertEqual(app.state.moveStatusFilter, .safe)
    }

    func testFilterFrameFitsFixedTerminalRows() {
        var state = TUIState()
        state.currentScreen = .appFilter(restoring: false)
        state.moveFilterStatusDraft = .blocked
        state.moveFilterSizeDraft = .atLeast10GB
        let frame = TerminalRenderer().render(state: state, width: 80, height: 24)
        let rows = frame.components(separatedBy: "\r\n")

        XCTAssertEqual(rows.count, 24)
        XCTAssertTrue(rows.contains { $0.contains("Filter Move Applications") })
        XCTAssertTrue(rows.contains { $0.contains("≥ 10 GB") })
        let escape = String(UnicodeScalar(27))
        let visibleRows = rows.map {
            $0.replacingOccurrences(of: escape + "\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        XCTAssertTrue(visibleRows.allSatisfy { $0.count <= 80 })
    }
}
