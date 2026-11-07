import Foundation
import XCTest
@testable import MacBayKit

final class DirectoryMigratorSafetyTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-safety-\(UUID().uuidString)")
        source = root.appendingPathComponent("Archives")
        destination = root.appendingPathComponent("external/Archives")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first archive".utf8).write(to: source.appendingPathComponent("first.bin"))
        try Data("second archive".utf8).write(to: source.appendingPathComponent("second.bin"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItemMakingWritable(at: root) }

    private func migrator(_ manager: FileManager = .default) -> DirectoryMigrator {
        DirectoryMigrator(fileManager: manager, commandRunner: TestBundleCommandRunner(entitlementsXml: ""))
    }

    private func assertComplete(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("first.bin")), Data("first archive".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("second.bin")), Data("second archive".utf8), file: file, line: line)
    }

    func testSuccessfulMigrationPreservesBothArchivesAndRemovesBackup() throws {
        _ = try migrator().migrate(source: source, destination: destination, operation: "test", dryRun: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), destination.path)
        try assertComplete(source)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".Archives.macbay-") }.isEmpty)
    }

    func testPartialBackupRemovalKeepsCompleteDestinationAndWorkingOriginalPath() throws {
        let manager = MigrationFailureFileManager()
        manager.failBackupRemoval = true
        XCTAssertThrowsError(try migrator(manager).migrate(source: source, destination: destination, operation: "test", dryRun: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains(self.destination.path))
            XCTAssertTrue(error.localizedDescription.contains("backup"))
        }
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path), destination.path)
        try assertComplete(destination)
        try assertComplete(source)
        let backup = try XCTUnwrap(manager.backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("first.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("second.bin").path))
    }

    func testFailedLinkRollsBackCompleteOriginalBeforeRemovingCopy() throws {
        let manager = MigrationFailureFileManager()
        manager.failLink = true
        XCTAssertThrowsError(try migrator(manager).migrate(source: source, destination: destination, operation: "test", dryRun: false))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        try assertComplete(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFailedRollbackKeepsBothCompleteCopiesAndReportsTheirPaths() throws {
        let manager = MigrationFailureFileManager()
        manager.failLink = true
        manager.failRollback = true
        XCTAssertThrowsError(try migrator(manager).migrate(source: source, destination: destination, operation: "test", dryRun: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains(self.destination.path))
            XCTAssertTrue(error.localizedDescription.contains(manager.backup?.path ?? "missing backup"))
        }
        try assertComplete(destination)
        try assertComplete(XCTUnwrap(manager.backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testVerificationFailureLeavesOriginalCompleteAndRemovesUnverifiedCopy() throws {
        XCTAssertThrowsError(try migrator().migrate(source: source, destination: destination, operation: "test", dryRun: false,
            verify: { _ in throw NSError(domain: "Verification", code: 1) }))
        try assertComplete(source)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

/// Simulates removal that deletes one archive before hitting a permission error.
final class MigrationFailureFileManager: FileManager, @unchecked Sendable {
    var failBackupRemoval = false
    var failLink = false
    var failRollback = false
    var backup: URL?

    override func removeItem(at url: URL) throws {
        if failBackupRemoval, url.lastPathComponent.contains(".macbay-") {
            try super.removeItem(at: url.appendingPathComponent("first.bin"))
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.removeItem(at: url)
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if destination.lastPathComponent.contains(".macbay-") { backup = destination }
        if failRollback, source.lastPathComponent.contains(".macbay-") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.moveItem(at: source, to: destination)
    }

    override func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
        if failLink { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try super.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }
}
