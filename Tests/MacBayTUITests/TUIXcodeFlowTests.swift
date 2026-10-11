import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIXcodeFlowTests: XCTestCase {
    private let drive = StorageVolume(name: "External", path: "/Volumes/External", isInternal: false,
                                      totalBytes: 1_000_000_000, availableBytes: 500_000_000)

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
        for _ in 0..<5 { app.handleKey(.down) }
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
        assertFrame(app)
        return app
    }

    private func assertFrame(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.renderString(width: 80, height: 24).components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, file: file, line: line)
        for row in rows {
            let plain = row.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            XCTAssertEqual(plain.count, 80, file: file, line: line)
        }
    }

    private func preview(_ app: TUIApp) {
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        guard case .xcodePreview = app.state.currentScreen else { return XCTFail("Missing preview") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        assertFrame(app)
    }

    private func confirm(_ app: TUIApp) {
        app.handleKey(.right)
        app.handleKey(.enter)
        guard case .xcodeConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        assertFrame(app)
    }

    func testStandardAndOptionalActionsUseSamePreviewOptionsAndDestination() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        let app = open(service)
        XCTAssertEqual(app.state.xcodeVolumePath, drive.path)
        XCTAssertEqual(app.state.xcodeOptions, XcodeDoctorOptions())
        XCTAssertTrue(app.renderString().contains("DeviceSupport and Archives"))
        app.handleKey(.down)
        app.handleKey(.char(" ")) // Externalize DerivedData.
        app.handleKey(.down)
        app.handleKey(.right) // Clean DerivedData.
        app.handleKey(.down)
        app.handleKey(.right) // Clean caches.
        let options = app.state.xcodeOptions
        XCTAssertEqual(options, XcodeDoctorOptions(externalizeDerivedData: true, cleanDerivedData: true, cleanCaches: true))
        preview(app)
        confirm(app)
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertEqual(service.xcodeExecutions.count, 1)
        XCTAssertEqual(service.xcodeExecutions[0].options, options)
        XCTAssertEqual(service.xcodeExecutions[0].volumePath, drive.path)
        XCTAssertEqual(service.xcodePlans.count, 1)
        XCTAssertEqual(service.xcodePlans[0].1, options)
        guard case .xcodeResult = app.state.currentScreen else { return XCTFail("Missing result") }
        assertFrame(app)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
        XCTAssertEqual(app.state.xcodeOptions, options)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
        XCTAssertTrue(app.renderString().contains("Xcode Storage"))
        XCTAssertTrue(app.renderString().contains("Quit"))
    }

    func testBothPreviewAndSeparateConfirmationCancelByDefault() {
        for escape in [false, true] {
            let service = FakeTUIService(eligibleVolumes: [drive])
            let app = open(service)
            preview(app)
            app.handleKey(escape ? .escape : .enter)
            XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
            preview(app)
            confirm(app)
            app.handleKey(escape ? .escape : .enter)
            guard case .xcodePreview = app.state.currentScreen else { return XCTFail("Must return to preview") }
            app.handleKey(.escape)
            XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
            XCTAssertTrue(service.xcodeExecutions.isEmpty)
        }
    }

    func testNoVolumeAndDisconnectedDefaultDoNotFallBackSilently() {
        let missing = DefaultVolume(path: "/Volumes/Missing", name: "Missing", savedAt: "")
        let service = FakeTUIService(eligibleVolumes: [drive], defaultVolume: missing)
        let app = open(service)
        XCTAssertEqual(app.state.xcodeVolumePath, missing.path)
        app.handleKey(.enter)
        XCTAssertTrue(service.xcodePlans.isEmpty)
        XCTAssertTrue(app.renderString().contains("Destination unavailable"))
        app.handleKey(.right)
        XCTAssertEqual(app.state.xcodeVolumePath, drive.path)
        preview(app)

        let emptyService = FakeTUIService()
        let empty = open(emptyService)
        empty.handleKey(.right)
        empty.handleKey(.enter)
        XCTAssertEqual(empty.state.currentScreen, .xcodeOptions)
        XCTAssertTrue(emptyService.xcodePlans.isEmpty)
        XCTAssertTrue(emptyService.xcodeExecutions.isEmpty)
        assertFrame(empty)
    }

    func testMultipleVolumesRequireExplicitSelection() {
        let second = StorageVolume(name: "Second", path: "/Volumes/Second", isInternal: false,
                                   totalBytes: 1000, availableBytes: 500)
        let service = FakeTUIService(eligibleVolumes: [drive, second])
        let app = open(service)
        XCTAssertNil(app.state.xcodeVolumePath)
        app.handleKey(.enter)
        XCTAssertTrue(service.xcodePlans.isEmpty)
        app.handleKey(.right)
        app.handleKey(.right)
        XCTAssertEqual(app.state.xcodeVolumePath, second.path)
        preview(app)
        guard case .xcodePreview(let plan) = app.state.currentScreen else { return XCTFail() }
        XCTAssertEqual(plan.volumePath, second.path)
    }

    func testRunningXcodeRequiresExplicitForceAndForceConfirmation() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        service.xcodeRunning = true
        let app = open(service)
        XCTAssertFalse(app.state.xcodeOptions.force)
        XCTAssertTrue(app.renderString().contains("Xcode is running"))
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
        // The refusal names the TUI's Force option, not the CLI's --force flag.
        XCTAssertFalse(app.state.errorMessage?.contains("--force") ?? true)
        XCTAssertTrue(app.state.errorMessage?.contains("enable Force") ?? false)
        for _ in 0..<4 { app.handleKey(.down) }
        app.handleKey(.char(" "))
        XCTAssertTrue(app.state.xcodeOptions.force)
        preview(app)
        XCTAssertTrue(app.renderString().contains("Force accepted"))
        confirm(app)
        XCTAssertTrue(app.renderString().contains("Force & Execute"))
        app.handleKey(.enter) // Default Cancel.
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
    }

    func testChangedConditionsReturnToOptionsAndNeedFreshPreview() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        service.xcodeExecutionError = XcodePlanError.conditionsChanged("Drive disconnected")
        let app = open(service)
        preview(app)
        confirm(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertTrue(app.renderString().contains("No actions were executed"))
        XCTAssertTrue(app.renderString().contains("fresh preview"))
        assertFrame(app)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .xcodeOptions)
        XCTAssertEqual(service.xcodeExecutions.count, 1)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        guard case .xcodePreview = app.state.currentScreen else { return XCTFail("Fresh preview required") }
        XCTAssertEqual(service.xcodePlans.count, 2)
        XCTAssertEqual(service.xcodeExecutions.count, 1)
    }

    func testPartialResultsAndLongFailureDetailsAreScrollableAt80By24() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        let migration = MigrationResult(operation: "externalize", name: "DeviceSupport",
            sourcePath: "/home/Library/Developer/Xcode/iOS DeviceSupport",
            destinationPath: drive.path + "/MacBay/Xcode/iOS DeviceSupport", sizeBytes: 1024, dryRun: true, messages: [])
        service.xcodePlanReport = XcodeDoctorReport(deviceSupport: migration, simulatorCleanup: nil)
        service.xcodeReport = XcodeDoctorReport(deviceSupport: migration,
            simulatorCleanup: CommandResultSummary(command: "delete unavailable", succeeded: false, output: "Simulator tool failed"),
            cacheCleanup: CommandResultSummary(command: "clean caches", succeeded: false, output: "Locked cache\nPer-target failure details"),
            freedBytes: 1024,
            failedActions: (0..<20).map { XcodeActionFailure(action: "Archives item \($0)", reason: "Permission denied for archive \($0)") })
        let app = open(service)
        preview(app)
        confirm(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("finished with failures"))
        XCTAssertTrue(frame.contains("Completed: DeviceSupport"))
        XCTAssertTrue(frame.contains("reclaimed: 1.0 KB"))
        XCTAssertTrue(frame.contains("Simulator tool failed"))
        assertFrame(app)
        for _ in 0..<150 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Permission denied for archive 19"))
        XCTAssertTrue(app.renderString().contains("Return to options"))
        assertFrame(app)
    }

    func testLongPreviewKeepsButtonsVisibleAndLoadingCannotChangeOptions() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        let path = String(repeating: "long-folder/", count: 20)
        service.xcodePlanReport = XcodeDoctorReport(deviceSupport: MigrationResult(operation: "externalize", name: "DeviceSupport",
            sourcePath: "/home/" + path, destinationPath: drive.path + "/" + path,
            sizeBytes: 1024, dryRun: true, messages: Array(repeating: "Preview guidance for selected action", count: 35)))
        let app = open(service)
        service.artificialDelay = 0.1
        app.handleKey(.enter)
        app.handleKey(.down)
        app.handleKey(.char(" "))
        XCTAssertEqual(app.state.xcodeOptions, XcodeDoctorOptions())
        waitUntil { !app.state.isLoading }
        guard case .xcodePreview = app.state.currentScreen else { return XCTFail() }
        for _ in 0..<100 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Continue to Confirmation"))
        assertFrame(app)
        confirm(app)
        for _ in 0..<100 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Confirm & Execute"))
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
        assertFrame(app)
    }

    func testFailedEnvironmentCanRetryAndNavigationDoesNotOpenLatePreview() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        service.xcodeEnvironmentError = MacBayError.unsupportedOperation("Process check unavailable")
        let app = open(service)
        app.handleKey(.enter)
        XCTAssertTrue(service.xcodePlans.isEmpty)
        XCTAssertTrue(app.renderString().contains("Process check unavailable"))
        service.xcodeEnvironmentError = nil
        app.handleKey(.char("r"))
        waitUntil { !app.state.isLoading }
        XCTAssertTrue(app.state.xcodeEnvironmentLoaded)
        service.artificialDelay = 0.1
        app.handleKey(.enter)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .home)
        XCTAssertTrue(service.xcodeExecutions.isEmpty)
    }

    func testDeferredQuitFinishesOneExecution() {
        let service = FakeTUIService(eligibleVolumes: [drive])
        let app = open(service)
        preview(app)
        confirm(app)
        service.artificialDelay = 0.1
        app.handleKey(.right)
        app.handleKey(.enter)
        XCTAssertTrue(app.state.isMutating)
        assertFrame(app)
        app.handleKey(.ctrlC)
        app.handleKey(.enter)
        XCTAssertTrue(app.state.quitDeferred)
        XCTAssertFalse(app.shouldExit)
        waitUntil { app.shouldExit }
        XCTAssertEqual(service.xcodeExecutions.count, 1)
    }
}
