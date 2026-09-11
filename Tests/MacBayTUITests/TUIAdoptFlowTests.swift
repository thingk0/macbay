import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIAdoptFlowTests: XCTestCase {

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

    private let appName = "UnmanagedApp.app"
    private let appVolume = "/Volumes/KLEVV"
    private let externalPath = "/Volumes/KLEVV/MacBay/Applications/UnmanagedApp.app"

    private func makeUnmanagedScan(
        name: String? = nil,
        destinationPath: String? = nil,
        size: UInt64 = 200_000_000
    ) -> ScanReport {
        let external = ExternalApplication(
            name: name ?? appName,
            sourcePath: "/Applications/\(name ?? appName)",
            destinationPath: destinationPath ?? externalPath,
            sizeBytes: size,
            managementStatus: .unmanaged
        )
        return ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [],
            externalApplications: [external],
            unresolvedApplicationLinks: []
        )
    }

    private func makeApp(
        scan: ScanReport? = nil,
        defaultVolume: DefaultVolume? = nil
    ) -> (fake: FakeTUIService, app: TUIApp) {
        let fake = FakeTUIService(scan: scan ?? makeUnmanagedScan(), defaultVolume: defaultVolume)
        fake.mountedVolumePaths = [appVolume]
        return (fake, TUIApp(service: fake))
    }

    private func openRestoreList(_ app: TUIApp) {
        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded }, "Scan must finish")
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
    }

    @discardableResult
    private func openAdoptReview(_ app: TUIApp, plan: AdoptPlan? = nil, fake: FakeTUIService) -> AdoptPlan? {
        fake.adoptPlanToReturn = plan
        app.handleKey(.enter)
        let opened = waitUntil {
            if case .adoptReview = app.state.currentScreen { return true }
            return false
        }
        guard opened else { return nil }
        if case let .adoptReview(current) = app.state.currentScreen { return current }
        return nil
    }

    private func isDryRunPreview(_ app: TUIApp) -> Bool {
        if case .dryRunPreview = app.state.currentScreen { return true }
        return false
    }

    private func isAdoptOutcome(_ app: TUIApp) -> Bool {
        if case .adoptOutcome = app.state.currentScreen { return true }
        return false
    }

    // MARK: - Notice title

    func testNoticeTitleRendersOnlyOnce() {
        let blocked = AppCandidate(
            name: "Blocked.app",
            path: "/Applications/Blocked.app",
            sizeBytes: 700_000_000,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .blocked,
                reasons: ["Hypervisor entitlement present"],
                evidence: ["com.apple.security.hypervisor"]
            )
        )
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [blocked],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let app = TUIApp(service: FakeTUIService(scan: scan))
        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })

        app.handleKey(.enter)
        app.handleKey(.enter)
        guard case .infoModal = app.state.currentScreen else {
            return XCTFail("Expected infoModal, got \(app.state.currentScreen)")
        }

        let frame = app.renderString(width: 80, height: 24)
        let occurrences = frame.components(separatedBy: "Notice:").count - 1
        XCTAssertEqual(occurrences, 1, "Notice title must appear once, in the header only")
        XCTAssertTrue(frame.contains("Application Blocked"), "Header must still name the notice")
        XCTAssertTrue(frame.contains("Recommended Action:"), "Body must keep the guidance")
    }

    // MARK: - Adoption review

    func testUnmanagedRestoreEntryOffersAdoptionReview() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let listFrame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(
            listFrame.contains("review adoption into MacBay standard storage"),
            "Restore list must point at [Enter] for adoption"
        )
        XCTAssertFalse(listFrame.contains("mb adopt"), "Restore list must no longer send users to the CLI")

        let plan = openAdoptReview(app, fake: fake)
        XCTAssertEqual(plan?.appName, appName)
        XCTAssertEqual(fake.adoptPlanCalls.first?.volumePath, appVolume)
    }

    func testAdoptionCancellationDoesNotExecute() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }
        XCTAssertEqual(app.state.adoptReviewFocusIndex, 0, "Cancel must hold focus by default")

        app.handleKey(.enter)

        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
        XCTAssertEqual(fake.adoptPlanCalls.count, 1, "Only the read-only plan may run")
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty, "Cancelling must not adopt")
        XCTAssertTrue(fake.undockCalls.isEmpty, "Cancelling must not prepare a restore preview")
    }

    func testAdoptionReviewShowsLocationsModeAndLinkChange() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(appName: appName, volumePath: appVolume, mode: .moveAndAdopt)
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Adoption Review"), "Header must name the screen")
        XCTAssertTrue(frame.contains("Current Location:"))
        XCTAssertTrue(frame.contains("Standard Storage:"))
        XCTAssertTrue(frame.contains("Link Change:"))
        XCTAssertTrue(
            frame.contains("→ \(appVolume)/MacBay/Applications/\(appName)"),
            "Link target must be readable, not shortened into the source path"
        )
        XCTAssertTrue(frame.contains("Move bundle to standard storage and register"), "Mode must say files move")
        XCTAssertTrue(frame.contains("[ Cancel ]"))
        XCTAssertTrue(frame.contains("[ Confirm & Adopt ]"))
    }

    func testRegisterOnlyAdoptionSaysNothingMoves() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let destination = "\(appVolume)/MacBay/Applications/\(appName)"
        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            mode: .registerOnly,
            targetPath: destination,
            destinationPath: destination
        )
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Register only"), "Mode must say that no files move")
    }

    func testReviewRequiredAdoptionNeedsRiskConsentBeforeConfirming() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            status: .reviewRequired(reasons: ["Contains helper tool"], evidence: ["SMPrivilegedExecutables"]),
            mode: .moveAndAdopt
        )
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        let initial = app.renderString(width: 80, height: 24)
        XCTAssertTrue(initial.contains("[ Accept Risk & Continue ]"), "Risk must be acknowledged first")
        XCTAssertFalse(initial.contains("[ Confirm & Adopt ]"), "Adoption must not be offered before consent")

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(app.state.adoptRiskAccepted, "Pressing the accept button must record consent")
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty, "Consent alone must not adopt")
        let consented = app.renderString(width: 80, height: 24)
        XCTAssertTrue(consented.contains("[ Confirm & Adopt ]"), "Adoption becomes available after consent")
        XCTAssertTrue(consented.contains("Risk accepted"), "Consent must stay visible on the review")

        app.handleKey(.enter)
        XCTAssertTrue(waitUntil { fake.adoptExecuteCalls.count == 1 }, "Confirmation must adopt")
        XCTAssertEqual(fake.adoptExecuteCalls.first?.force, true, "Review-required plans execute with force")
    }

    func testBlockedAdoptionShowsReasonAndSolutionWithoutConfirming() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            status: .blocked(reason: "Hypervisor entitlement present", solution: "Remove virtualization entitlements before migrating."),
            mode: .moveAndAdopt
        )
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Blocked:"))
        XCTAssertTrue(frame.contains("Hypervisor entitlement present"))
        XCTAssertTrue(frame.contains("Solution:"))
        XCTAssertTrue(frame.contains("Remove virtualization entitlements before migrating."))
        XCTAssertTrue(frame.contains("[ Close ]"))
        XCTAssertFalse(frame.contains("[ Confirm & Adopt ]"), "Blocked plans must not offer adoption")
        XCTAssertFalse(frame.contains("[ Accept Risk & Continue ]"), "Blocked plans cannot be forced")

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty, "Blocked plans must never execute")
    }

    func testConflictingAdoptionExplainsConflictWithoutConfirming() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            status: .conflict(reason: "Manifest records another source path"),
            mode: .moveAndAdopt
        )
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Conflict:"))
        XCTAssertTrue(frame.contains("Manifest records another source path"))
        XCTAssertTrue(frame.contains("mb doctor"))
        XCTAssertFalse(frame.contains("[ Confirm & Adopt ]"))
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty)
    }

    func testAlreadyAdoptedSkipsReviewAndMakesNoChanges() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            status: .alreadyAdopted(details: "Already adopted: application is already located at standard MacBay path."),
            mode: .alreadyAdopted
        )
        fake.adoptPlanToReturn = plan
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { isDryRunPreview(app) }, "Already adopted apps go straight to the restore preview")
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty, "No changes are needed for an adopted app")
        XCTAssertFalse(app.state.adoptRiskAccepted)

        guard case let .dryRunPreview(preview) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(preview.operation, "undock")
        XCTAssertEqual(preview.volumePath, appVolume)
        XCTAssertTrue(preview.notice?.contains("Already registered") == true)
    }

    // MARK: - Adoption execution

    func testAdoptionSuccessOpensRestorePreviewOnItsOwnVolume() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { isDryRunPreview(app) }, "Restore preview must follow a successful adoption")
        XCTAssertEqual(fake.adoptExecuteCalls.count, 1)

        guard case let .dryRunPreview(preview) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(preview.appName, appName)
        XCTAssertEqual(preview.volumePath, appVolume, "Restore preview must use the volume that was adopted")
        XCTAssertTrue(preview.notice?.contains("Adoption completed") == true, "Preview must report the adoption")
        XCTAssertEqual(fake.undockCalls.last?.volumePath, appVolume)
        XCTAssertEqual(fake.undockCalls.last?.dryRun, true)

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Adoption completed"), "Restore screen must show the adoption result")
    }

    func testAdoptionCompletionRepaintsWithoutKeyInput() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        fake.artificialDelay = 0.05
        app.handleKey(.right)
        app.handleKey(.enter)
        _ = app.consumeRedrawRequest()

        XCTAssertTrue(waitUntil { isDryRunPreview(app) }, "Preview must appear on its own")
        XCTAssertTrue(app.consumeRedrawRequest(), "Async completion must request a redraw without key input")
    }

    func testRestoreAfterAdoptionRequiresSeparateConfirmation() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertTrue(waitUntil { isDryRunPreview(app) })
        XCTAssertEqual(app.state.confirmFocusIndex, 0, "Cancel must hold focus on the restore preview")

        app.handleKey(.enter)

        XCTAssertEqual(app.state.currentScreen, .appRestoreList, "Cancelling the restore returns to the list")
        XCTAssertTrue(fake.undockCalls.allSatisfy { $0.dryRun }, "Restore must not run without its own confirmation")
        XCTAssertFalse(
            app.state.navigationStack.contains { if case .adoptReview = $0 { return true }; return false },
            "Adoption review must not come back into the screen history"
        )
    }

    func testRestoreConfirmationAfterAdoptionRunsUndockOnAdoptedVolume() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertTrue(waitUntil { isDryRunPreview(app) })

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { !app.state.isMutating })
        let mutations = fake.undockCalls.filter { !$0.dryRun }
        XCTAssertEqual(mutations.count, 1, "Restore must run exactly once")
        XCTAssertEqual(mutations.first?.volumePath, appVolume)
    }

    func testRepeatedEnterDoesNotAdoptTwice() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        app.handleKey(.right)
        for _ in 0..<5 {
            app.handleKey(.enter)
        }

        XCTAssertTrue(waitUntil { !app.state.isMutating })
        XCTAssertEqual(fake.adoptExecuteCalls.count, 1, "Repeated confirmation must not adopt twice")
    }

    // MARK: - Failure reporting

    func testAdoptionFailureShowsStageAndRollbackWithoutRestorePreview() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        fake.shouldThrowExecuteAdopt = AdoptExecutionError(
            stage: "execution",
            message: "manifest write failed",
            rollback: .succeeded(actions: ["Restored original symlink at /Applications/\(appName)"])
        )

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { isAdoptOutcome(app) }, "Failure screen must appear")
        XCTAssertFalse(app.state.isMutating)
        XCTAssertTrue(app.consumeRedrawRequest(), "Failure must request a redraw without key input")

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Adoption Failed"))
        XCTAssertTrue(frame.contains("Failed Stage:"))
        XCTAssertTrue(frame.contains("execution"))
        XCTAssertTrue(frame.contains("manifest write failed"))
        XCTAssertTrue(frame.contains("Rollback:"))
        XCTAssertTrue(frame.contains("Restored original symlink"), "Rollback result must be reported")
        XCTAssertTrue(frame.contains("mb doctor"))
        XCTAssertFalse(frame.contains("Dry-Run Migration Preview"), "Failure must not continue to the restore preview")
        XCTAssertTrue(fake.undockCalls.isEmpty)
    }

    func testFailedAdoptionRollbackReportsManualIntervention() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        fake.shouldThrowExecuteAdopt = AdoptExecutionError(
            stage: "execution",
            message: "link swap failed",
            rollback: .failed(
                error: "Failed to restore symlink at /Applications/\(appName)",
                manualInterventionNeeded: ["Inspect application symlink at /Applications/\(appName)"]
            )
        )

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { isAdoptOutcome(app) })
        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("link swap failed"))
        XCTAssertTrue(frame.contains("Failed to restore symlink"), "Rollback error must be reported")
        XCTAssertTrue(frame.contains("Manual Intervention Needed:"))
        XCTAssertTrue(frame.contains("Inspect application symlink"))
        XCTAssertTrue(frame.contains("not guaranteed to be in its original state"), "State must not be over-promised")
        XCTAssertFalse(frame.contains("No files were harmed"), "Message must not claim the app is untouched")
    }

    func testAdoptionSuccessWithPreviewFailureReportsBothResults() {
        let (fake, app) = makeApp()
        openRestoreList(app)
        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        fake.shouldThrowUndock = MacBayError.manifestFailed(
            path: "\(appVolume)/.macbay/manifest.json",
            details: "record read failed"
        )

        app.handleKey(.right)
        app.handleKey(.enter)

        XCTAssertTrue(waitUntil { isAdoptOutcome(app) }, "Preview failure must surface after the adoption")
        XCTAssertEqual(fake.adoptExecuteCalls.count, 1, "The adoption itself must have run")

        let frame = app.renderString(width: 80, height: 24)
        XCTAssertTrue(frame.contains("Adoption Completed"), "Adoption result must still be reported")
        XCTAssertTrue(frame.contains("Restore Preview Failed"), "Preview failure must be a separate section")
        XCTAssertTrue(frame.contains("record read failed"))
        XCTAssertTrue(frame.contains("only the restore preview failed"))
        XCTAssertTrue(frame.contains("mb doctor"))
    }

    // MARK: - Volume selection

    func testAdoptionUsesApplicationVolumeRatherThanDefaultVolume() {
        let defaultVolume = DefaultVolume(
            path: "/Volumes/Other",
            name: "Other",
            uuid: nil,
            savedAt: macBayTimestamp()
        )
        let (fake, app) = makeApp(defaultVolume: defaultVolume)
        fake.mountedVolumePaths = ["/Volumes/Other", appVolume]
        openRestoreList(app)

        guard openAdoptReview(app, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        XCTAssertEqual(fake.adoptPlanCalls.count, 1)
        XCTAssertEqual(fake.adoptPlanCalls.first?.volumePath, appVolume, "Adoption must target the app's own volume")

        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertTrue(waitUntil { isDryRunPreview(app) })
        XCTAssertEqual(fake.undockCalls.last?.volumePath, appVolume, "Restore preview must stay on that volume")
        XCTAssertFalse(fake.undockCalls.contains { $0.volumePath == "/Volumes/Other" })
    }

    func testUnresolvableVolumeBlocksAdoption() {
        let (fake, app) = makeApp()
        fake.mountedVolumePaths = []
        openRestoreList(app)

        app.handleKey(.enter)

        let opened = waitUntil {
            if case .infoModal = app.state.currentScreen { return true }
            return false
        }
        XCTAssertTrue(opened, "Unresolved volume must be reported instead of planning")

        guard case let .infoModal(title, message, guidance) = app.state.currentScreen else {
            return XCTFail("Expected infoModal, got \(app.state.currentScreen)")
        }
        XCTAssertTrue(title.contains("Volume Not Resolved"))
        XCTAssertTrue(message.contains(externalPath), "Reason must name the unresolved path")
        XCTAssertTrue(guidance?.contains("Adoption stays disabled") == true)
        XCTAssertTrue(fake.adoptPlanCalls.isEmpty, "Adoption must not be planned without a verified volume")
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty)
    }

    func testPlanningFailureIsReportedWithoutExecuting() {
        let (fake, app) = makeApp()
        openRestoreList(app)

        fake.shouldThrowPlanAdopt = MacBayError.manifestFailed(
            path: "\(appVolume)/.macbay/manifest.json",
            details: "Unsupported manifest version 2"
        )
        app.handleKey(.enter)

        let opened = waitUntil {
            if case .infoModal = app.state.currentScreen { return true }
            return false
        }
        XCTAssertTrue(opened)
        guard case let .infoModal(title, message, guidance) = app.state.currentScreen else {
            return XCTFail("Expected infoModal, got \(app.state.currentScreen)")
        }
        XCTAssertTrue(title.contains("Adoption Review Failed"))
        XCTAssertTrue(message.contains("manifest"))
        XCTAssertTrue(guidance?.contains("Unsupported manifest version 2") == true, "Details must reach the user")
        XCTAssertTrue(fake.adoptExecuteCalls.isEmpty)
    }

    // MARK: - Layout

    func testAdoptReviewKeepsButtonsPinnedWithLongContent() {
        let longVolume = "/Volumes/" + String(repeating: "DeeplyNestedVolumeName", count: 4)
        let longName = String(repeating: "VeryLongApplicationName", count: 4) + ".app"
        let reasons = (0..<40).map { "Risk factor \($0): requires elevated permissions to install helper tooling" }
        let evidence = (0..<40).map { "SMPrivilegedExecutables[\($0)]" }

        let scan = makeUnmanagedScan(name: longName, destinationPath: "\(longVolume)/MacBay/Applications/\(longName)")
        let fake = FakeTUIService(scan: scan)
        fake.mountedVolumePaths = [longVolume]
        let app = TUIApp(service: fake)

        app.loadScan()
        XCTAssertTrue(waitUntil { app.state.scanLoaded })
        app.handleKey(.down)
        app.handleKey(.enter)

        fake.adoptPlanToReturn = FakeTUIService.makeAdoptPlan(
            appName: longName,
            volumePath: longVolume,
            status: .reviewRequired(reasons: reasons, evidence: evidence)
        )
        app.handleKey(.enter)
        XCTAssertTrue(waitUntil {
            if case .adoptReview = app.state.currentScreen { return true }
            return false
        })

        let frame = app.renderString(width: 80, height: 24)
        let rows = frame.components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, "Frame must keep exactly 24 rows")
        for row in rows {
            XCTAssertEqual(visibleWidth(row), 80, "Every row must be exactly 80 columns: \(row)")
        }
        XCTAssertTrue(rows[20].contains("Scroll · lines"), "Overflowing body must advertise scrolling")
        XCTAssertTrue(rows[21].contains("[ Accept Risk & Continue ]"), "Buttons must stay pinned to the bottom")
        XCTAssertTrue(rows[22].contains("─"), "Status line must remain visible below the buttons")
    }

    func testAdoptReviewScrollsBodyWithoutMovingButtons() {
        let reasons = (0..<40).map { "Risk factor \($0)" }
        let (fake, app) = makeApp()
        openRestoreList(app)

        let plan = FakeTUIService.makeAdoptPlan(
            appName: appName,
            volumePath: appVolume,
            status: .reviewRequired(reasons: reasons, evidence: [])
        )
        guard openAdoptReview(app, plan: plan, fake: fake) != nil else {
            return XCTFail("Adopt review must open")
        }

        guard let metrics = TerminalRenderer().scrollableDetailMetrics(state: app.state, width: 80, height: 24) else {
            return XCTFail("adoptReview should expose scroll metrics")
        }
        XCTAssertGreaterThan(metrics.total, metrics.viewport, "Fixture must overflow the viewport")

        let initial = app.renderString(width: 80, height: 24)
        for _ in 0..<200 {
            app.handleKey(.down)
        }
        XCTAssertEqual(app.state.detailScrollOffset, metrics.total - metrics.viewport, "Scroll must clamp to the body")

        let scrolled = app.renderString(width: 80, height: 24)
        XCTAssertTrue(scrolled.contains("[ Accept Risk & Continue ]"), "Buttons stay pinned while the body scrolls")
        XCTAssertNotEqual(initial, scrolled, "Scrolling must move the body")

        for _ in 0..<200 {
            app.handleKey(.up)
        }
        XCTAssertEqual(app.state.detailScrollOffset, 0)
    }
}
