import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIStateTests: XCTestCase {

    private func makeSafeCandidate(name: String = "TestApp.app", size: UInt64 = 500_000_000) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: size,
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .safe)
        )
    }

    private func makeReviewCandidate(name: String = "RiskApp.app", size: UInt64 = 600_000_000) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: size,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .popupRisk,
                reasons: ["Contains helper tool"],
                evidence: ["SMPrivilegedExecutables"]
            )
        )
    }

    private func makeBlockedCandidate(name: String = "BlockedApp.app", size: UInt64 = 700_000_000) -> AppCandidate {
        AppCandidate(
            name: name,
            path: "/Applications/\(name)",
            sizeBytes: size,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .blocked,
                reasons: ["Hypervisor entitlement present"],
                evidence: ["com.apple.security.hypervisor"]
            )
        )
    }

    private func makeVolume(name: String, path: String) -> StorageVolume {
        StorageVolume(
            name: name,
            path: path,
            isInternal: false,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000
        )
    }

    func testInitialStateAndNavigationBack() {
        let fake = FakeTUIService()
        let app = TUIApp(service: fake)

        XCTAssertEqual(app.state.currentScreen, .home)

        // Move menu selection
        app.handleKey(.down)
        XCTAssertEqual(app.state.homeMenuIndex, 1)
        app.handleKey(.down)
        XCTAssertEqual(app.state.homeMenuIndex, 2)
        app.handleKey(.up)
        XCTAssertEqual(app.state.homeMenuIndex, 1)
        app.handleKey(.up)
        XCTAssertEqual(app.state.homeMenuIndex, 0)

        // Enter Move Application
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)

        // Esc goes back to Home
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)

        // Enter Restore Application
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)

        // Enter Doctor (menu index 2: from 1, press down once)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .doctorSummary)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
    }

    func testEmptyListsDoNotCrash() {
        let fake = FakeTUIService(
            status: nil,
            scan: ScanReport(
                generatedAt: macBayTimestamp(),
                minimumApplicationSizeBytes: 100,
                candidates: [],
                externalApplications: [],
                unresolvedApplicationLinks: []
            ),
            doctor: DoctorReport(
                generatedAt: macBayTimestamp(),
                volumes: [],
                findings: [],
                summary: DoctorSummary(checked: 0, healthy: 0, unmanaged: 0, needsAttention: 0, unableToVerify: 0),
                warnings: []
            )
        )
        let app = TUIApp(service: fake)

        // Enter Move List (menu index 0)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertTrue(app.state.moveCandidates.isEmpty)
        app.handleKey(.up)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        app.handleKey(.escape)

        // Enter Restore List (menu index 1)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
        XCTAssertTrue(app.state.restoreItems.isEmpty)
        app.handleKey(.up)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)
        app.handleKey(.escape)

        // Enter Doctor List (menu index 2: press down once from 1)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .doctorSummary)
        XCTAssertTrue(app.state.doctorFindings.isEmpty)
        app.handleKey(.up)
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .doctorSummary)
    }

    func testVolumeSelectionAppliesToSession() {
        let vol1 = makeVolume(name: "SSD1", path: "/Volumes/SSD1")
        let vol2 = makeVolume(name: "SSD2", path: "/Volumes/SSD2")
        let candidate = makeSafeCandidate()
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [candidate],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan, eligibleVolumes: [vol1, vol2])
        let app = TUIApp(service: fake)
        app.loadScan()

        // Wait for scan to load
        let exp = expectation(description: "Scan loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Open move list
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)

        // Select candidate -> since 2 volumes exist, should show volume selection
        app.handleKey(.enter)
        guard case .volumeSelect = app.state.currentScreen else {
            return XCTFail("Expected volumeSelect screen, got \(app.state.currentScreen)")
        }

        // Navigate to second volume and select
        app.handleKey(.down)
        XCTAssertEqual(app.state.volumeSelectIndex, 1)
        app.handleKey(.enter)

        // Verify session volume path was set
        XCTAssertEqual(app.state.sessionVolumePath, "/Volumes/SSD2")

        // Wait for dry run
        let exp2 = expectation(description: "Dry run preview")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        guard case let .dryRunPreview(plan) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(plan.volumePath, "/Volumes/SSD2")
    }

    func testConfirmationCancellationDoesNotMutate() {
        let vol = makeVolume(name: "SSD", path: "/Volumes/SSD")
        let candidate = makeSafeCandidate()
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [candidate],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan, eligibleVolumes: [vol])
        let app = TUIApp(service: fake)
        app.loadScan()

        let exp = expectation(description: "Scan loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Navigate to move list and select app
        app.handleKey(.enter)
        app.handleKey(.enter)

        let exp2 = expectation(description: "Dry run loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        guard case .dryRunPreview = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }

        // Default focus must be Cancel (0)
        XCTAssertEqual(app.state.confirmFocusIndex, 0)

        // Press enter on Cancel
        app.handleKey(.enter)

        // Returned to list
        XCTAssertEqual(app.state.currentScreen, .appMoveList)

        // Ensure no real mutating calls were made
        let mutatingCalls = fake.dockCalls.filter { !$0.dryRun }
        XCTAssertTrue(mutatingCalls.isEmpty, "Mutating dock call must not happen when cancelled")
    }

    func testReviewCandidateRequiresRiskAcceptance() {
        let vol = makeVolume(name: "SSD", path: "/Volumes/SSD")
        let candidate = makeReviewCandidate()
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [candidate],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan, eligibleVolumes: [vol])
        let app = TUIApp(service: fake)
        app.loadScan()

        let exp = expectation(description: "Scan loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Navigate to move list
        app.handleKey(.enter)
        // Select candidate
        app.handleKey(.enter)

        // Should be on riskReview screen
        guard case .riskReview = app.state.currentScreen else {
            return XCTFail("Expected riskReview screen, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(app.state.riskFocusIndex, 0) // Default Cancel

        // If user presses Enter on Cancel:
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appMoveList)
        XCTAssertTrue(fake.dockCalls.isEmpty)

        // Select again, switch to Accept Risk (1)
        app.handleKey(.enter)
        app.handleKey(.right)
        XCTAssertEqual(app.state.riskFocusIndex, 1)
        app.handleKey(.enter)

        let exp2 = expectation(description: "Dry run loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        guard case let .dryRunPreview(plan) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertTrue(plan.force, "Force must be true when risk is accepted")
        XCTAssertEqual(fake.dockCalls.first?.force, true)
    }

    func testBlockedCandidateCannotBeMoved() {
        let candidate = makeBlockedCandidate()
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [candidate],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan)
        let app = TUIApp(service: fake)
        app.loadScan()

        let exp = expectation(description: "Scan loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        app.handleKey(.enter)
        app.handleKey(.enter)

        guard case let .infoModal(title, _, _) = app.state.currentScreen else {
            return XCTFail("Expected infoModal for blocked app, got \(app.state.currentScreen)")
        }
        XCTAssertTrue(title.contains("Blocked"))
        XCTAssertTrue(fake.dockCalls.isEmpty, "Blocked app must never trigger dock call")
    }

    func testDuplicateExecutionIsPrevented() {
        let vol = makeVolume(name: "SSD", path: "/Volumes/SSD")
        let candidate = makeSafeCandidate()
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [candidate],
            externalApplications: [],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan, eligibleVolumes: [vol])
        let app = TUIApp(service: fake)

        // Set state to loading
        app.loadScan()
        XCTAssertTrue(app.state.isLoading)

        // Try to trigger move while loading
        let initialDockCalls = fake.dockCalls.count
        app.handleKey(.enter)
        XCTAssertEqual(fake.dockCalls.count, initialDockCalls)
    }

    func testRestoreUnmanagedDisplaysGuidance() {
        let unmanaged = ExternalApplication(
            name: "UnmanagedApp.app",
            sourcePath: "/Applications/UnmanagedApp.app",
            destinationPath: "/Volumes/External/UnmanagedApp.app",
            sizeBytes: 200_000_000,
            managementStatus: .unmanaged
        )
        let scan = ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: 100,
            candidates: [],
            externalApplications: [unmanaged],
            unresolvedApplicationLinks: []
        )
        let fake = FakeTUIService(scan: scan)
        let app = TUIApp(service: fake)
        app.loadScan()

        let exp = expectation(description: "Scan loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Open Restore list
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .appRestoreList)

        // Select unmanaged app
        app.handleKey(.enter)
        guard case let .infoModal(title, _, guidance) = app.state.currentScreen else {
            return XCTFail("Expected infoModal for unmanaged app, got \(app.state.currentScreen)")
        }
        XCTAssertTrue(title.contains("Unmanaged"))
        XCTAssertTrue(guidance?.contains("adopt") == true)
        XCTAssertTrue(fake.undockCalls.isEmpty, "Unmanaged app cannot be restored with undock")
    }

    func testTerminalRendererResizeNotice() {
        let fake = FakeTUIService()
        let app = TUIApp(service: fake)

        // Small size
        let smallOutput = app.renderString(width: 70, height: 18)
        XCTAssertTrue(smallOutput.contains("Terminal Window Too Small"))
        XCTAssertTrue(smallOutput.contains("MacBay TUI requires at least 80 x 24"))

        // Standard size
        let normalOutput = app.renderString(width: 80, height: 24)
        XCTAssertTrue(normalOutput.contains("MacBay"))
        XCTAssertTrue(normalOutput.contains("Storage Overview"))
    }
}
