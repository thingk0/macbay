import Foundation
import XCTest
@testable import MacBayKit

final class PermissionPreservingMoveTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionPreservingMoveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItemMakingWritable(at: tempDir)
    }

    /// Go 모듈 캐시처럼 루트와 모듈 디렉터리가 읽기 전용인 트리.
    private func makeReadOnlyTree() throws -> URL {
        let root = tempDir.appendingPathComponent("mod")
        let module = root.appendingPathComponent("golang.org/x/text@v0.1.0")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try Data("module golang.org/x/text".utf8).write(to: module.appendingPathComponent("go.mod"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: module.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        return root
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    func testMoveKeepsReadOnlyModesAtDestination() throws {
        let root = try makeReadOnlyTree()
        let moved = tempDir.appendingPathComponent(".mod.macbay-backup")

        try FileManager.default.moveItemPreservingPermissions(at: root, to: moved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try mode(of: moved), 0o500)
        XCTAssertEqual(try mode(of: moved.appendingPathComponent("golang.org/x/text@v0.1.0")), 0o555)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("golang.org/x/text@v0.1.0/go.mod").path
        ))
    }

    func testFailedMoveRestoresModesAtSource() throws {
        let root = try makeReadOnlyTree()
        let unreachable = tempDir.appendingPathComponent("missing-parent/mod")

        XCTAssertThrowsError(try FileManager.default.moveItemPreservingPermissions(at: root, to: unreachable))

        XCTAssertEqual(try mode(of: root), 0o500)
        XCTAssertEqual(try mode(of: root.appendingPathComponent("golang.org/x/text@v0.1.0")), 0o555)
    }

    func testRemoveItemMakingWritableDeletesReadOnlyTree() throws {
        let root = try makeReadOnlyTree()

        try FileManager.default.removeItemMakingWritable(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
