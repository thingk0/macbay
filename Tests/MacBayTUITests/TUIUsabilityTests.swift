import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIUsabilityTests: XCTestCase {
    func testHeaderUsesSharedReleaseVersion() {
        let frame = TerminalRenderer().render(state: TUIState(), width: 80, height: 24)
        XCTAssertTrue(frame.contains("v\(MacBayVersion.current)"))
    }

    private func wait(_ app: TUIApp, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition())
    }

    private func candidate(_ name: String, _ size: UInt64, _ grade: CompatibilityGrade) -> AppCandidate {
        AppCandidate(name: name, path: "/Applications/" + name, sizeBytes: size, kind: .application, compatibility: CompatibilityAssessment(grade: grade))
    }

    func testSearchCapturesShortcutsAndEscapeClearsWithoutLeavingList() {
        let service = FakeTUIService(scan: ScanReport(generatedAt: "", minimumApplicationSizeBytes: 0, candidates: [candidate("Query.app", 20, .safe), candidate("Other.app", 30, .blocked)]))
        let app = TUIApp(service: service)
        app.loadScan()
        wait(app) { !app.state.isLoading }
        app.handleKey(.enter)
        app.handleKey(.down)
        app.handleKey(.char("/"))
        for c in "query" { app.handleKey(.char(c)) }
        XCTAssertFalse(app.shouldExit)
        XCTAssertEqual(service.scanCalls, 1)
        XCTAssertEqual(app.state.moveCandidates.map(\.name), ["Query.app"])
        XCTAssertEqual(app.state.moveListIndex, 0)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        app.handleKey(.char("/"))
        app.handleKey(.backspace)
        XCTAssertEqual(app.state.moveSearch, "quer")
        app.handleKey(.escape)
        XCTAssertEqual(app.state.moveSearch, "")
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
    }

    func testFilterSortAndEmptySelectionNeverStartMigration() {
        let service = FakeTUIService(scan: ScanReport(generatedAt: "", minimumApplicationSizeBytes: 0, candidates: [candidate("Zulu.app", 30, .safe), candidate("Alpha.app", 20, .safe), candidate("Risk.app", 40, .popupRisk)]))
        let app = TUIApp(service: service)
        app.loadScan()
        wait(app) { !app.state.isLoading }
        app.handleKey(.enter)
        app.handleKey(.char("f"))
        app.handleKey(.char("s"))
        XCTAssertEqual(app.state.moveCandidates.map(\.name), ["Alpha.app", "Zulu.app"])
        app.handleKey(.char("/"))
        app.handleKey(.char("없"))
        app.handleKey(.enter)
        app.handleKey(.enter)
        XCTAssertTrue(service.dockCalls.isEmpty)
        XCTAssertTrue(app.renderString().contains("No matching applications"))
        app.handleKey(.char("c"))
        XCTAssertEqual(app.state.moveCandidates.count, 3)
    }

    private func recoveryFixture(status: RepairPlanStatus = .ready) -> (TUIApp, FakeTUIService) {
        let finding = DoctorFinding(code: .localDataDetected, status: .needsAttention, category: .record, name: "Example.app", paths: ["/Applications/Example.app", "/Volumes/SSD/Example.app"], detail: "Duplicate copies", recommendation: "Compare copies")
        let service = FakeTUIService(doctor: DoctorReport(generatedAt: "", volumes: [], findings: [finding], summary: DoctorSummary(checked: 1, healthy: 0, unmanaged: 0, needsAttention: 1, unableToVerify: 0), warnings: []))
        let local = AppCopyInfo(path: finding.paths[0], bundleIdentifier: "example", version: "2", buildNumber: "2", sizeBytes: 100, signatureStatus: "valid", compatibilityGrade: "Safe")
        let external = AppCopyInfo(path: finding.paths[1], bundleIdentifier: "example", version: "1", buildNumber: "1", sizeBytes: 90, signatureStatus: "valid", compatibilityGrade: "Safe")
        service.repairComparison = RepairComparison(appName: finding.name, volumePath: "/Volumes/SSD", localCopy: local, externalCopy: external, canRedock: true)
        service.repairPlan = RepairPlan(action: .redock, appName: finding.name, localURL: URL(fileURLWithPath: local.path), externalURL: URL(fileURLWithPath: external.path), backupURL: URL(fileURLWithPath: "/Volumes/SSD/backup/Example.app"), stagingURL: nil, volumeURL: URL(fileURLWithPath: "/Volumes/SSD"), status: status, sizeBytes: 100, requiredExternalSpaceBytes: 100, estimatedFreedInternalBytes: 100)
        let app = TUIApp(service: service)
        app.loadDoctor()
        wait(app) { !app.state.isLoading }
        app.handleKey(.down); app.handleKey(.down); app.handleKey(.enter); app.handleKey(.enter)
        return (app, service)
    }

    private func openPreview(_ app: TUIApp) {
        app.handleKey(.char("p"))
        wait(app) { !app.state.isLoading }
        app.handleKey(.right); app.handleKey(.enter)
        wait(app) { !app.state.isLoading }
    }

    func testRecoveryRequiresSeparatePreviewAndConfirmation() {
        let (app, service) = recoveryFixture()
        openPreview(app)
        XCTAssertTrue(service.repairExecutions.isEmpty)
        XCTAssertEqual(app.state.recoveryFocus, 0)
        XCTAssertTrue(app.renderString().contains("Confirm repair"))
        app.handleKey(.enter) // Default Cancel
        XCTAssertTrue(service.repairExecutions.isEmpty)
        app.handleKey(.right); app.handleKey(.enter)
        wait(app) { !app.state.isLoading }
        app.handleKey(.right); app.handleKey(.enter)
        wait(app) { !app.state.isMutating }
        XCTAssertEqual(service.repairExecutions.count, 1)
        XCTAssertFalse(service.repairExecutions[0].1)
    }

    func testBlockedPreviewCannotExecuteAndRiskIsExplicit() {
        let (blocked, service) = recoveryFixture(status: .blocked(reason: "Blocked", solution: "Keep local"))
        openPreview(blocked)
        blocked.handleKey(.right); blocked.handleKey(.enter)
        XCTAssertTrue(service.repairExecutions.isEmpty)
        let (risk, riskService) = recoveryFixture(status: .reviewRequired(reasons: ["Helper risk"], evidence: []))
        openPreview(risk)
        XCTAssertTrue(risk.renderString().contains("Accept risk & repair"))
        risk.handleKey(.right); risk.handleKey(.enter)
        wait(risk) { !risk.state.isMutating }
        XCTAssertEqual(riskService.repairExecutions.count, 1)
        XCTAssertTrue(riskService.repairExecutions[0].1)
    }

    func testRecoveryFailureOffersRecheckAndLatePlanDoesNotNavigate() {
        let (app, service) = recoveryFixture()
        service.repairError = MacBayError.unsupportedOperation("conditions changed")
        openPreview(app)
        app.handleKey(.right); app.handleKey(.enter)
        wait(app) { !app.state.isMutating && !app.state.isLoading }
        XCTAssertTrue(app.renderString().contains("conditions changed"))
        XCTAssertTrue(app.renderString().contains("Recheck diagnosis"))
        let (late, delayed) = recoveryFixture()
        delayed.artificialDelay = 0.15
        late.handleKey(.char("p")); late.handleKey(.escape)
        wait(late) { !late.state.isLoading }
        XCTAssertEqual(late.state.currentScreen, .doctorSummary)
    }

    func testRollbackRequiresJournalPreviewAndExplicitConfirmation() throws {
        let (app, service) = recoveryFixture()
        app.handleKey(.escape)
        let finding = DoctorFinding(code: .incompleteOperation, status: .needsAttention, category: .applicationLink, name: "Example.app", paths: ["/Applications/Example.app", "/Volumes/SSD/Example.app"], detail: "Interrupted repair", recommendation: "Review rollback")
        service.doctorToReturn = DoctorReport(generatedAt: "", volumes: [], findings: [finding], summary: DoctorSummary(checked: 1, healthy: 0, unmanaged: 0, needsAttention: 1, unableToVerify: 0), warnings: [])
        let item = DockedItem(name: finding.name, sourcePath: finding.paths[0], externalPath: finding.paths[1], sizeBytes: 100, kind: .application, dockedAt: "")
        let record = RepairJournalRecord(id: "fixture", appName: item.name, localPath: item.sourcePath, externalPath: item.externalPath, backupPath: "/Volumes/SSD/backup", stagingPath: "/Volumes/SSD/staging", localBackupPath: "/Applications/backup", volumePath: "/Volumes/SSD", phase: .staged, timestamp: "", originalManifestItem: item)
        service.rollbackRecord = record
        app.loadDoctor(force: true)
        wait(app) { !app.state.isLoading }
        app.handleKey(.enter); app.handleKey(.char("b"))
        wait(app) { !app.state.isLoading }
        XCTAssertEqual(service.rollbackExecutions, 0)
        XCTAssertTrue(app.renderString().contains("Confirm rollback"))
        app.handleKey(.enter)
        XCTAssertEqual(service.rollbackExecutions, 0)
        app.handleKey(.char("b"))
        wait(app) { !app.state.isLoading }
        app.handleKey(.right); app.handleKey(.enter)
        wait(app) { !app.state.isMutating }
        XCTAssertEqual(service.rollbackExecutions, 1)
        // Real adapter must reject a stale/missing journal before touching paths.
        XCTAssertThrowsError(try DefaultTUIService().executeRollback(record: record))
    }

    func testRestoreSearchHasIndependentStateAndSizeSort() {
        let service = FakeTUIService()
        let items = [DockedItem(name: "Alpha.app", sourcePath: "/Applications/Alpha.app", externalPath: "/tmp/Alpha.app", sizeBytes: 10, kind: .application, dockedAt: ""), DockedItem(name: "Zulu.app", sourcePath: "/Applications/Zulu.app", externalPath: "/tmp/Zulu.app", sizeBytes: 20, kind: .application, dockedAt: "")]
        service.statusToReturn = StatusReport(generatedAt: "", internalVolume: service.statusToReturn.internalVolume, externalVolumes: [], dockedItems: items)
        let app = TUIApp(service: service)
        app.loadInitialData()
        wait(app) { !app.state.isLoading }
        app.handleKey(.down); app.handleKey(.enter)
        app.handleKey(.char("s"))
        XCTAssertEqual(app.state.restoreItems.map(\.name), ["Zulu.app", "Alpha.app"])
        app.handleKey(.char("/")); app.handleKey(.char("z")); app.handleKey(.enter)
        XCTAssertEqual(app.state.restoreItems.count, 1)
        XCTAssertEqual(app.state.moveSearch, "")
        app.handleKey(.char("f")); app.handleKey(.char("c"))
        XCTAssertEqual(app.state.restoreItems.count, 2)
        XCTAssertFalse(app.state.restoreManagedOnly)
    }

    func testProgressEstimateStaysVisibleWithManyCompletedSteps() {
        var state = TUIState()
        state.currentScreen = .mutatingProgress(operation: "dock", appName: "Example.app")
        state.currentStepLabel = "Copying application"
        state.completedSteps = (0..<30).map { CompletedStep(label: "Step \($0)", duration: 1) }
        state.copyProgress = CopyProgress(observedBytes: 100, totalBytes: 100, elapsed: 2)
        state.quitDeferred = true
        let frame = TerminalRenderer().render(state: state, width: 80, height: 24)
        XCTAssertTrue(frame.contains("Copy estimate: 99%"))
        XCTAssertTrue(frame.contains("verification follows"))
        XCTAssertTrue(frame.contains("Quit requested"))
        XCTAssertEqual(frame.components(separatedBy: "\r\n").count, 24)
    }
}
