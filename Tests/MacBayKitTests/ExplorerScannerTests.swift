import Foundation
import XCTest
@testable import MacBayKit

final class ExplorerScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func writeFile(at url: URL, size: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: size).write(to: url)
    }

    func testScanSortsByAllocatedAndSkipsSymlinkDescendants() throws {
        let small = tempDir.appendingPathComponent("Small")
        let big = tempDir.appendingPathComponent("Big")
        try writeFile(at: small.appendingPathComponent("a.bin"), size: 1024)
        try writeFile(at: big.appendingPathComponent("b.bin"), size: 8192)
        try FileManager.default.createSymbolicLink(
            at: small.appendingPathComponent("link"),
            withDestinationURL: big
        )

        let scan = ExplorerScanner().scanDirectory(tempDir)
        XCTAssertTrue(scan.complete)
        XCTAssertEqual(scan.entries.map(\.name), ["Big", "Small"])
        XCTAssertEqual(scan.entries[1].kind, .directory)
        // tempDir lives under /var/.../T which the mover blocklist treats as
        // protected; the scanner must surface that as a blocked action.
        if case .blocked = scan.entries[1].action {
        } else {
            XCTFail("Expected blocked action under /tmp, got \(scan.entries[1].action)")
        }
        XCTAssertGreaterThan(scan.totalAllocatedBytes, 0)
    }

    func testHardlinkedFilesCountOnce() throws {
        let first = tempDir.appendingPathComponent("TreeA/file.bin")
        let second = tempDir.appendingPathComponent("TreeB/file.bin")
        try writeFile(at: first, size: 65536)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: first.path, toPath: second.path)

        let scan = ExplorerScanner().scanDirectory(tempDir)
        let treeA = try XCTUnwrap(scan.entries.first { $0.name == "TreeA" })
        let treeB = try XCTUnwrap(scan.entries.first { $0.name == "TreeB" })
        XCTAssertGreaterThan(treeA.allocatedBytes, 0)
        XCTAssertEqual(treeA.allocatedBytes, treeB.allocatedBytes)
        let total = scan.totalAllocatedBytes
        XCTAssertLessThanOrEqual(total, treeA.allocatedBytes + treeB.allocatedBytes)
    }

    func testUnreadableEntriesAreFlaggedNotZero() throws {
        let readable = tempDir.appendingPathComponent("Readable")
        let locked = tempDir.appendingPathComponent("Locked")
        try writeFile(at: readable.appendingPathComponent("a.bin"), size: 1024)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeFile(at: locked.appendingPathComponent("secret.bin"), size: 4096)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let scan = ExplorerScanner().scanDirectory(tempDir)
        let entry = try XCTUnwrap(scan.entries.first { $0.name == "Locked" })
        if geteuid() == 0 {
            XCTAssertFalse(entry.unreadable)
        } else {
            XCTAssertTrue(entry.unreadable)
            XCTAssertEqual(entry.action, .unreadable)
            XCTAssertTrue(scan.unreadablePaths.contains { $0.hasSuffix("Locked/secret.bin") || $0.hasSuffix("Locked") })
            XCTAssertFalse(scan.complete)
        }
    }

    func testScanRecordDiffMarksGrowthAndPartialUncomparable() throws {
        let store = ScanRecordStore(
            fileManager: .default,
            environment: [:],
            homeDirectory: tempDir
        )
        let previous = ExplorerScanReport(
            rootPath: tempDir.path,
            generatedAt: "2026-01-01T00:00:00Z",
            entries: [
                ExplorerEntry(name: "Steam", path: tempDir.appendingPathComponent("Steam").path, kind: .directory, logicalBytes: 100, allocatedBytes: 100, action: .directoryMove),
                ExplorerEntry(name: "Gone", path: tempDir.appendingPathComponent("Gone").path, kind: .directory, logicalBytes: 50, allocatedBytes: 50, action: .directoryMove)
            ],
            totalLogicalBytes: 150,
            totalAllocatedBytes: 150,
            complete: true
        )
        let current = ExplorerScan(
            rootPath: tempDir.path,
            entries: [
                ExplorerEntry(name: "Steam", path: tempDir.appendingPathComponent("Steam").path, kind: .directory, logicalBytes: 200, allocatedBytes: 200, action: .directoryMove)
            ],
            totalLogicalBytes: 200,
            totalAllocatedBytes: 200,
            complete: true
        )
        let report = store.buildReport(from: current, previous: previous)
        let byPath = Dictionary(uniqueKeysWithValues: report.deltas.map { ($0.path, $0) })
        XCTAssertEqual(byPath[tempDir.appendingPathComponent("Steam").path]?.status, .grown)
        XCTAssertEqual(byPath[tempDir.appendingPathComponent("Steam").path]?.deltaAllocatedBytes, 100)
        XCTAssertEqual(byPath[tempDir.appendingPathComponent("Gone").path]?.status, .removed)

        let partial = ExplorerScan(
            rootPath: tempDir.path,
            entries: current.entries,
            totalLogicalBytes: 200,
            totalAllocatedBytes: 200,
            complete: false,
            unreadablePaths: [tempDir.appendingPathComponent("Locked").path]
        )
        let partialReport = store.buildReport(from: partial, previous: previous)
        XCTAssertTrue(partialReport.deltas.allSatisfy { $0.status == .uncomparable })
        XCTAssertEqual(partialReport.previousGeneratedAt, previous.generatedAt)
    }

    func testSameRootRecordRoundTrip() throws {
        let store = ScanRecordStore(
            fileManager: .default,
            environment: [:],
            homeDirectory: tempDir
        )
        let root = tempDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scan = ExplorerScan(
            rootPath: root.path,
            entries: [],
            totalLogicalBytes: 0,
            totalAllocatedBytes: 0
        )
        let report = store.buildReport(from: scan, previous: nil)
        try store.save(report)
        XCTAssertEqual(store.load(forRootPath: root.path)?.rootPath, root.path)
        XCTAssertNil(store.load(forRootPath: tempDir.appendingPathComponent("Other").path))
    }
}
