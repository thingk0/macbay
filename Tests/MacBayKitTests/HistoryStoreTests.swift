import Foundation
import XCTest
@testable import MacBayKit

final class HistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = HistoryStore(
            environment: ["XDG_STATE_HOME": tempDir.appendingPathComponent("state").path],
            homeDirectory: tempDir
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func entry(command: String, subject: String, outcome: HistoryOutcome = .success, undo: String? = nil) -> HistoryEntry {
        HistoryEntry(command: command, subject: subject, outcome: outcome, undo: undo)
    }

    func testHistoryPathUsesXdgStateHome() {
        XCTAssertTrue(store.historyURL.path.hasPrefix(tempDir.appendingPathComponent("state/macbay").path))
        XCTAssertTrue(store.historyURL.path.hasSuffix("history.jsonl"))
    }

    func testHistoryPathFallsBackToDotLocalState() {
        let fallback = HistoryStore(environment: [:], homeDirectory: tempDir)
        XCTAssertEqual(
            fallback.historyURL.path,
            tempDir.appendingPathComponent(".local/state/macbay/history.jsonl").path
        )
    }

    func testRecordAppendsEntriesNewestFirst() throws {
        store.record(entry(command: "dock", subject: "A.app", undo: "mb undock \"A.app\""))
        store.record(entry(command: "move", subject: "~/Games"))
        store.record(entry(command: "purge", subject: "3 item(s)", outcome: .failure))

        let entries = store.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].command, "purge")
        XCTAssertEqual(entries[0].outcome, .failure)
        XCTAssertEqual(entries[1].command, "move")
        XCTAssertEqual(entries[2].undo, "mb undock \"A.app\"")
    }

    func testEntriesFiltersByCommandAndLimit() throws {
        store.record(entry(command: "dock", subject: "A.app"))
        store.record(entry(command: "dock", subject: "B.app"))
        store.record(entry(command: "teardown", subject: "all volumes"))

        XCTAssertEqual(store.entries(command: "dock").count, 2)
        XCTAssertEqual(store.entries(limit: 1).count, 1)
        XCTAssertEqual(store.entries(command: "cache").count, 0)
    }

    func testCorruptLinesAreSkipped() throws {
        let url = store.historyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = try JSONEncoder().encode(entry(command: "dock", subject: "A.app"))
        try (Data("not-json\n".utf8) + good + Data("\n".utf8)).write(to: url)

        XCTAssertEqual(store.entries().count, 1)
    }

    func testRotationKeepsOnePreviousGeneration() throws {
        let url = store.historyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Oversized existing file is rotated away before the new append.
        try Data(String(repeating: "x", count: 6 * 1024 * 1024).utf8).write(to: url)

        store.record(entry(command: "dock", subject: "A.app"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rotatedURL.path))
        // Rotated content is not decodable, only the fresh entry is listed.
        XCTAssertEqual(store.entries().count, 1)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(size, 10_000)
    }

    func testEntriesOnMissingFileReturnsEmpty() {
        XCTAssertTrue(store.entries().isEmpty)
    }
}
