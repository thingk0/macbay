import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIPurgeServiceTests: XCTestCase {
    private final class Processes: @unchecked Sendable, CommandRunner {
        var names = ""
        func run(_ executable: String, arguments: [String]) throws -> CommandResult {
            CommandResult(status: 0, standardOutput: names)
        }
    }

    private final class FailingRemoval: FileManager, @unchecked Sendable {
        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent == "locked.bin" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try super.removeItem(at: URL)
        }
    }

    private var home: URL!
    private var history: HistoryStore!
    private var processes: Processes!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("macbay-tui-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let canonicalPath = try home.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? home.path
        home = URL(fileURLWithPath: canonicalPath)
        history = HistoryStore(environment: [:], homeDirectory: home)
        processes = Processes()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func cache(app: String = "Example", name: String = "Code Cache", file: String = "data.bin", bytes: Int = 1024) throws -> URL {
        let directory = home.appendingPathComponent("Library/Application Support/\(app)/\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent(file)
        try Data(repeating: 1, count: bytes).write(to: payload)
        return payload
    }

    private func adapter(fileManager: FileManager = .default) -> DefaultTUIService {
        let engine = PurgeEngine(fileManager: fileManager, commandRunner: processes, homeDirectory: home)
        return DefaultTUIService(service: MacBayService(purgeEngine: engine), historyStore: history)
    }

    func testScanAndEmptyExecutionLeaveFilesAndHistoryUntouched() throws {
        let payload = try cache()
        let service = adapter()
        let items = try service.scanPurge()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sizeBytes, 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.historyURL.path))
        let report = try service.executePurge(items: [])
        XCTAssertEqual(report.totalReclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.stateDirectory.path))
    }

    func testSharedWhitelistAndSymlinkRulesProtectUserData() throws {
        let payload = try cache()
        let sensitive = try cache(name: "IndexedDB")
        let linked = payload.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GPUCache")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: sensitive.deletingLastPathComponent())
        let service = adapter()
        let items = try service.scanPurge()
        XCTAssertEqual(items.map(\.path), [payload.deletingLastPathComponent().path])
        let report = try service.executePurge(items: items)
        XCTAssertEqual(report.totalReclaimedBytes, 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sensitive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertEqual(entry.command, "purge")
        XCTAssertEqual(entry.subject, "1 item(s)")
        XCTAssertEqual(entry.outcome, .success)
        XCTAssertEqual(entry.detail, "freed 1.0 KB")
        XCTAssertNil(entry.undo)
    }

    func testApplicationStartingAfterPreviewIsSkippedBySharedEngine() throws {
        let payload = try cache()
        let service = adapter()
        let items = try service.scanPurge()
        XCTAssertFalse(items[0].isRunning)
        processes.names = "/Applications/Example.app/Contents/MacOS/Example\n"
        let report = try service.executePurge(items: items)
        XCTAssertTrue(report.purgedItems.isEmpty)
        XCTAssertEqual(report.skippedItems.map(\.path), items.map(\.path))
        XCTAssertTrue(report.skippedItems[0].isRunning)
        XCTAssertEqual(report.totalReclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testPartialRemovalRecordsActualBytesAndPartialHistory() throws {
        let removed = try cache(bytes: 2048)
        let retained = try cache(file: "locked.bin", bytes: 512)
        let service = adapter(fileManager: FailingRemoval())
        let items = try service.scanPurge()
        let report = try service.executePurge(items: items)
        XCTAssertEqual(report.totalReclaimedBytes, 2048)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertEqual(report.failedItems[0].path, retained.path)
        XCTAssertEqual(report.failedItems[0].unreclaimedBytes, 512)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(history.entries().count, 1)
        XCTAssertEqual(history.entries()[0].outcome, .partial)
        XCTAssertEqual(history.entries()[0].detail, "freed 2.0 KB, 1 failed")
    }

    func testCacheReplacedBySymlinkAfterScanIsRejectedAndRecorded() throws {
        let payload = try cache()
        let sensitive = try cache(name: "IndexedDB")
        let service = adapter()
        let items = try service.scanPurge()
        let directory = payload.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: sensitive.deletingLastPathComponent())
        let report = try service.executePurge(items: items)
        XCTAssertEqual(report.totalReclaimedBytes, 0)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertEqual(report.failedItems[0].reason, "Path is a symbolic link")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sensitive.path))
        XCTAssertEqual(history.entries()[0].outcome, .partial)
    }

    func testCancellationThroughActualAdapterWritesNoHistory() throws {
        let payload = try cache()
        let app = TUIApp(service: adapter())
        for _ in 0..<4 { app.handleKey(.down) }
        app.handleKey(.enter)
        let deadline = Date().addingTimeInterval(3)
        while app.state.purgeLoading && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(app.state.purgeLoaded)
        app.handleKey(.char("a"))
        app.handleKey(.enter)
        app.handleKey(.right)
        app.handleKey(.enter)
        guard case .purgeConfirmation = app.state.currentScreen else { return XCTFail("Missing confirmation") }
        app.handleKey(.enter) // Default Cancel.
        app.handleKey(.escape)
        app.handleKey(.escape)
        XCTAssertEqual(app.state.currentScreen, .home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.stateDirectory.path))
    }
}
