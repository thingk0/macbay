import Foundation
import XCTest
@testable import MacBayKit

final class ExplorerWatchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerWatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeService() -> MacBayService {
        MacBayService(
            fileManager: .default,
            historyStore: HistoryStore(
                fileManager: .default,
                environment: [:],
                homeDirectory: tempDir
            )
        )
    }

    private func stateHome() -> URL {
        tempDir.appendingPathComponent("state-home")
    }

    func testPartialRefreshUpdatesOnlyChangedEntry() throws {
        let root = tempDir.appendingPathComponent("Root")
        let steam = root.appendingPathComponent("Steam")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: steam.appendingPathComponent("a.bin"))
        try Data(repeating: 0x41, count: 1024).write(to: other.appendingPathComponent("b.bin"))

        let service = makeService()
        let first = try service.explore(path: root.path)
        let otherBefore = try XCTUnwrap(first.entries.first { $0.name == "Other" })

        try Data(repeating: 0x42, count: 65536).write(to: steam.appendingPathComponent("grown.bin"))
        let result = try XCTUnwrap(service.refreshExplorer(root: root.path, changedPaths: [steam.path]))
        XCTAssertFalse(result.fullRescan)
        XCTAssertEqual(result.refreshedPaths, [steam.standardizedFileURL.path])
        let steamAfter = try XCTUnwrap(result.report.entries.first { $0.name == "Steam" })
        let otherAfter = try XCTUnwrap(result.report.entries.first { $0.name == "Other" })
        XCTAssertGreaterThan(steamAfter.allocatedBytes, 4096)
        XCTAssertEqual(otherAfter.allocatedBytes, otherBefore.allocatedBytes)
        let delta = try XCTUnwrap(result.report.deltas.first { $0.path == steamAfter.path })
        XCTAssertEqual(delta.status, .grown)
    }

    func testRemovedEntryDisappearsOnPartialRefresh() throws {
        let root = tempDir.appendingPathComponent("Root")
        let gone = root.appendingPathComponent("Gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2048).write(to: gone.appendingPathComponent("a.bin"))

        let service = makeService()
        _ = try service.explore(path: root.path)
        try FileManager.default.removeItem(at: gone)

        let result = try XCTUnwrap(service.refreshExplorer(root: root.path, changedPaths: [gone.path]))
        XCTAssertFalse(result.fullRescan)
        XCTAssertTrue(result.report.entries.allSatisfy { $0.name != "Gone" })
    }

    func testDroppedEventsFallBackToFullRescan() throws {
        let root = tempDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: root.appendingPathComponent("Top.bin"))

        let service = makeService()
        _ = try service.explore(path: root.path)
        let result = try XCTUnwrap(service.refreshExplorer(
            root: root.path,
            changedPaths: [root.appendingPathComponent("Anything").path],
            droppedEvents: true
        ))
        XCTAssertTrue(result.fullRescan)
    }

    func testIrrelevantPathsReturnNil() throws {
        let root = tempDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = makeService()
        _ = try service.explore(path: root.path)
        XCTAssertNil(service.refreshExplorer(root: root.path, changedPaths: [tempDir.path]))
    }
}
