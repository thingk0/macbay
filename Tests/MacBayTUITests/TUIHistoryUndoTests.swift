import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIHistoryUndoTests: XCTestCase {
    private func entry(_ command: String, _ subject: String, _ outcome: HistoryOutcome = .success,
                       minute: Int = 0, detail: String? = nil) -> HistoryEntry {
        HistoryEntry(timestamp: String(format: "2026-10-10T10:%02d:00Z", minute), command: command,
                     subject: subject, outcome: outcome, detail: detail)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition())
    }

    private func assertFrame(_ app: TUIApp, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.renderString(width: 80, height: 24).components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 24, file: file, line: line)
        for row in rows {
            let plain = row.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            XCTAssertEqual(plain.count, 80, file: file, line: line)
        }
    }

    /// The frame's text with rows joined, so a phrase wrapped across rows still matches.
    private func flattened(_ app: TUIApp) -> String {
        app.renderString()
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .components(separatedBy: "\r\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    private func open(_ entries: [HistoryEntry]) -> (FakeTUIService, TUIApp) {
        let service = FakeTUIService()
        service.historyEntries = entries
        let app = TUIApp(service: service)
        for _ in 0..<6 { app.handleKey(.down) }
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading && app.state.historyLoaded }
        XCTAssertEqual(app.state.currentScreen, .historyList)
        assertFrame(app)
        return (service, app)
    }

    private func preview(_ app: TUIApp) {
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        guard case .undoPreview = app.state.currentScreen else { return XCTFail("Missing preview") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        assertFrame(app)
    }

    private func confirm(_ app: TUIApp) {
        app.handleKey(.right)
        app.handleKey(.enter)
        guard case .undoConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
        XCTAssertEqual(app.state.confirmFocusIndex, 0)
        assertFrame(app)
    }

    func testEligibleFlowUndoesLatestDockAfterDryRunAndConfirmation() {
        let (service, app) = open([entry("dock", "Xcode", minute: 5), entry("move", "/tmp/a", minute: 1)])
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("Can undo: dock Xcode"))
        XCTAssertTrue(frame.contains("mb undock 'Xcode'"))
        XCTAssertTrue(frame.contains("2026-10-10 10:05"))
        XCTAssertTrue(frame.contains("success"))
        preview(app)
        XCTAssertEqual(service.undoCalls.count, 1)
        XCTAssertTrue(service.undoCalls[0].dryRun)
        XCTAssertTrue(app.renderString().contains("changed nothing"))
        confirm(app)
        XCTAssertEqual(service.undoCalls.count, 1)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertEqual(service.undoCalls.map(\.dryRun), [true, false])
        guard case .undoResult(let report, let error, let attempted) = app.state.currentScreen else { return XCTFail("Missing result") }
        XCTAssertNotNil(report)
        XCTAssertNil(error)
        XCTAssertTrue(attempted)
        XCTAssertTrue(app.renderString().contains("Undo finished"))
        assertFrame(app)
        service.historyEntries.insert(entry("undo", "dock Xcode", minute: 6), at: 0)
        service.historyEntries.insert(entry("undock", "Xcode", minute: 6), at: 0)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .historyList)
        XCTAssertEqual(app.state.historyEntries.count, 4)
        XCTAssertNil(app.state.undoPlan)
        XCTAssertTrue(app.renderString().contains("already restored data"))
    }

    func testMoveIsUndoneWithUnmove() {
        let (service, app) = open([entry("move", "/Users/me/Big Folder")])
        XCTAssertTrue(app.renderString().contains("mb unmove"))
        preview(app)
        confirm(app)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertEqual(service.undoCalls.last?.plan.operation, .unmove)
    }

    func testCancellationAtPreviewAndConfirmationNeverMutates() {
        for escape in [false, true] {
            let (service, app) = open([entry("dock", "Xcode")])
            preview(app)
            app.handleKey(escape ? .escape : .enter)
            XCTAssertEqual(app.state.currentScreen, .historyList)
            preview(app)
            confirm(app)
            app.handleKey(escape ? .escape : .enter)
            guard case .undoPreview = app.state.currentScreen else { return XCTFail("Must return to preview") }
            app.handleKey(.escape)
            XCTAssertEqual(app.state.currentScreen, .historyList)
            XCTAssertTrue(service.undoCalls.allSatisfy(\.dryRun))
            XCTAssertFalse(service.undoCalls.isEmpty)
        }
    }

    func testStaleStateFromDryRunRefusesAndChangesNothing() {
        let (service, app) = open([entry("dock", "Xcode")])
        service.undoDryRunError = MacBayError.unsupportedOperation("Xcode is no longer docked; nothing to undock.")
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        guard case .undoResult(let report, let error, let attempted) = app.state.currentScreen else { return XCTFail("Missing refusal") }
        XCTAssertNil(report)
        XCTAssertFalse(attempted)
        XCTAssertEqual(error, "Xcode is no longer docked; nothing to undock.")
        XCTAssertTrue(app.renderString().contains("Nothing was undone"))
        assertFrame(app)
        app.handleKey(.enter)
        waitUntil { !app.state.isLoading }
        XCTAssertEqual(app.state.currentScreen, .historyList)
        XCTAssertEqual(service.undoCalls.count, 1)
    }

    func testStateChangingAfterConfirmationIsReportedWithoutPartialClaims() {
        let (service, app) = open([entry("dock", "Xcode")])
        preview(app)
        confirm(app)
        service.undoExecutionError = MacBayError.unsupportedOperation("Application is no longer docked")
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        guard case .undoResult(let report, let error, let attempted) = app.state.currentScreen else { return XCTFail() }
        XCTAssertNil(report)
        XCTAssertTrue(attempted)
        XCTAssertEqual(error, "Application is no longer docked")
        XCTAssertTrue(app.renderString().contains("Undo failed"))
        assertFrame(app)
    }

    func testHistoryChangingBetweenPreviewAndExecutionIsRefused() {
        let (service, app) = open([entry("dock", "Xcode")])
        preview(app)
        confirm(app)
        service.historyEntries.insert(entry("move", "/tmp/newer", minute: 9), at: 0)
        app.handleKey(.right)
        app.handleKey(.enter)
        waitUntil { !app.state.isMutating && !app.state.isLoading }
        XCTAssertEqual(service.undoCalls.map(\.dryRun), [true])
        XCTAssertTrue(app.renderString().contains("History changed since the preview"))
    }

    func testRefusalsExplainWhyForPartialAlreadyUndoneAndUnsupported() {
        let cases: [([HistoryEntry], String)] = [
            ([entry("dock", "Xcode", .partial)], "only partly succeeded"),
            ([entry("undock", "Xcode")], "already restored data"),
            ([entry("undo", "dock Xcode")], "never reverses an undo"),
            ([entry("purge", "3 item(s)")], "cannot be restored"),
            ([entry("dock", "Xcode", .failure)], "no successful operations"),
        ]
        for (entries, reason) in cases {
            let (service, app) = open(entries)
            let frame = flattened(app)
            XCTAssertTrue(frame.contains("Cannot undo") || frame.contains("Nothing to undo"), reason)
            XCTAssertFalse(frame.contains("Cannot undo: Cannot undo"), reason)
            XCTAssertTrue(frame.contains(reason), reason)
            app.handleKey(.enter)
            XCTAssertEqual(app.state.currentScreen, .historyList)
            XCTAssertNotNil(app.state.errorMessage)
            XCTAssertTrue(service.undoCalls.isEmpty)
            app.handleKey(.char("u"))
            XCTAssertTrue(service.undoCalls.isEmpty)
            assertFrame(app)
        }
    }

    func testLongRefusalWrapsAtWordsAndIsShownOnce() throws {
        let (_, app) = open([entry("undock", "Example.app")])
        let refusal = try XCTUnwrap(app.state.undoRefusal)
        let frame = app.renderString(width: 80, height: 24)
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let rows = frame.components(separatedBy: "\r\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Every word of the refusal survives intact on some row; none is cut across rows.
        let words = Set(rows.flatMap { $0.split(separator: " ").map(String.init) })
        for word in refusal.split(separator: " ") {
            XCTAssertTrue(words.contains(String(word)), "split word: \(word)")
        }
        XCTAssertEqual(frame.components(separatedBy: "already restored data").count - 1, 1)
        app.handleKey(.char("u"))
        XCTAssertEqual(app.state.errorMessage, "Nothing can be undone; the reason is shown above.")
        assertFrame(app)
    }

    func testOlderEntriesAreNotUndoableEvenWhenTheyAreDocks() {
        let (service, app) = open([entry("purge", "1 item(s)", minute: 9), entry("dock", "Xcode", minute: 1)])
        app.handleKey(.down)
        XCTAssertTrue(app.renderString().contains("Not undoable"))
        app.handleKey(.enter)
        XCTAssertTrue(service.undoCalls.isEmpty)
        XCTAssertNotNil(app.state.errorMessage)
    }

    func testFailedEntriesAreSkippedForEligibilityAndExplained() {
        let (_, app) = open([entry("dock", "Broken", .failure, minute: 9, detail: "no space"), entry("dock", "Xcode", minute: 1)])
        XCTAssertTrue(app.renderString().contains("Can undo: dock Xcode"))
        XCTAssertTrue(app.renderString().contains("no space"))
        XCTAssertTrue(app.renderString().contains("failed and changed nothing"))
    }

    func testEmptyHistoryShowsEmptyState() {
        let (service, app) = open([])
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("No recorded operations yet"))
        XCTAssertTrue(frame.contains("Nothing to undo"))
        app.handleKey(.enter)
        app.handleKey(.down)
        XCTAssertTrue(service.undoCalls.isEmpty)
        assertFrame(app)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
        XCTAssertTrue(app.renderString().contains("History & Undo"))
        XCTAssertTrue(app.renderString().contains("Quit"))
    }

    func testLongHistoryScrollsAndStaysWithin80By24() {
        let entries = (0..<60).map {
            entry($0 % 2 == 0 ? "purge" : "dock", String(repeating: "very-long-subject-", count: 8) + "\($0)", minute: $0 % 60)
        }
        let (_, app) = open(entries)
        assertFrame(app)
        for _ in 0..<59 { app.handleKey(.down) }
        XCTAssertEqual(app.state.historyIndex, 59)
        let frame = app.renderString()
        XCTAssertTrue(frame.contains("of 60"))
        XCTAssertTrue(frame.contains("Entries"))
        assertFrame(app)
        for _ in 0..<80 { app.handleKey(.up) }
        XCTAssertEqual(app.state.historyIndex, 0)
        XCTAssertEqual(app.state.historyScrollOffset, 0)
        assertFrame(app)
    }

    func testLongPreviewAndResultStayScrollableWithButtonsVisible() {
        let (service, app) = open([entry("dock", String(repeating: "Long Name ", count: 40))])
        _ = service
        preview(app)
        for _ in 0..<50 { app.handleKey(.down) }
        XCTAssertTrue(app.renderString().contains("Continue to Confirmation"))
        assertFrame(app)
        confirm(app)
        XCTAssertTrue(app.renderString().contains("Cancel"))
        assertFrame(app)
    }

    func testDeferredQuitFinishesOneUndo() {
        let (service, app) = open([entry("dock", "Xcode")])
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
        waitUntil { app.shouldExit }
        XCTAssertEqual(service.undoCalls.filter { !$0.dryRun }.count, 1)
    }
}

final class TUIHistoryUndoServiceTests: XCTestCase {
    func testDefaultServiceUsesSharedHistoryAndUndoPlanner() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macbay-tui-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HistoryStore(environment: [:], homeDirectory: home)
        let service = DefaultTUIService(historyStore: store)
        XCTAssertTrue(service.history(limit: nil).isEmpty)
        XCTAssertThrowsError(try service.planUndo())

        store.record(HistoryEntry(command: "dock", subject: "Example", outcome: .success))
        store.record(HistoryEntry(command: "purge", subject: "1 item(s)", outcome: .success))
        XCTAssertEqual(service.history(limit: 1).map(\.command), ["purge"])
        XCTAssertEqual(service.history(limit: nil).count, 2)
        XCTAssertThrowsError(try service.planUndo()) {
            XCTAssertTrue($0.localizedDescription.contains("cannot be restored"))
        }

        store.record(HistoryEntry(command: "dock", subject: "Example", outcome: .success))
        let plan = try service.planUndo()
        XCTAssertEqual(plan.operation, .undock)
        XCTAssertEqual(plan.command, "mb undock 'Example'")
    }
}
