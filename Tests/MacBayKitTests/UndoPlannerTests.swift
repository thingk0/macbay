import XCTest
@testable import MacBayKit

final class UndoPlannerTests: XCTestCase {
    private func entry(
        _ command: String,
        _ subject: String,
        _ outcome: HistoryOutcome = .success,
        undo: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(timestamp: "2026-09-13T08:00:00Z", command: command, subject: subject, outcome: outcome, undo: undo)
    }

    /// The refusal message, or nil when a plan was produced.
    private func refusal(_ entries: [HistoryEntry]) -> String? {
        do {
            _ = try UndoPlanner.plan(from: entries)
            return nil
        } catch let MacBayError.unsupportedOperation(message) {
            return message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    func testEmptyHistoryHasNothingToUndo() {
        XCTAssertEqual(refusal([])?.hasPrefix("Nothing to undo"), true)
    }

    func testDockIsUndoneWithQuotedUndock() throws {
        let plan = try UndoPlanner.plan(from: [entry("dock", "Final Cut Pro.app")])
        XCTAssertEqual(plan.operation, .undock)
        XCTAssertEqual(plan.target, "Final Cut Pro.app")
        XCTAssertEqual(plan.command, "mb undock 'Final Cut Pro.app'")
    }

    func testMoveIsUndoneWithQuotedUnmove() throws {
        let plan = try UndoPlanner.plan(from: [entry("move", "/Users/me/Game Library")])
        XCTAssertEqual(plan.operation, .unmove)
        XCTAssertEqual(plan.command, "mb unmove '/Users/me/Game Library'")
    }

    func testFailedAttemptsAreSkipped() throws {
        let plan = try UndoPlanner.plan(from: [
            entry("move", "/Users/me/Other", .failure),
            entry("dock", "Xcode.app")
        ])
        XCTAssertEqual(plan.entry.command, "dock")
        XCTAssertEqual(plan.target, "Xcode.app")
    }

    func testNewerNonUndoableOperationBlocksOlderDock() {
        let message = refusal([entry("purge", "3 item(s)"), entry("dock", "Xcode.app")])
        XCTAssertEqual(message?.contains("cannot be restored"), true, message ?? "planned")
    }

    func testPartialOutcomeIsRefused() {
        let message = refusal([entry("teardown", "all volumes", .partial)])
        XCTAssertEqual(message?.contains("only partly succeeded"), true, message ?? "planned")
    }

    func testAlreadyUndoneIsRefused() {
        let message = refusal([entry("undo", "dock Xcode.app"), entry("dock", "Xcode.app")])
        XCTAssertEqual(message?.contains("already an undo"), true, message ?? "planned")
    }

    func testRestoresPointToTheirReapplyHint() {
        let message = refusal([entry("undock", "Xcode.app", undo: "mb dock 'Xcode.app'")])
        XCTAssertEqual(message?.contains("mb dock 'Xcode.app'"), true, message ?? "planned")
    }

    func testEveryOtherOperationIsRefused() {
        let commands = [
            "adopt", "repair keep-local", "repair --rollback", "cache --enable", "cache --reset",
            "purge", "xcode", "teardown", "init", "init --reset", "doctor --fix", "undock", "unmove"
        ]
        for command in commands {
            XCTAssertNotNil(refusal([entry(command, "subject")]), "\(command) should not be undoable")
        }
    }
}
