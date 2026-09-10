import Foundation
import XCTest
@testable import MacBayKit

final class CacheManagerTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!
    private var volumeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        homeDir = tempDir.appendingPathComponent("UserHome")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        volumeURL = tempDir.appendingPathComponent("ExtDrive")
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDryRunDoesNotModifyFiles() throws {
        let manager = CacheManager(homeDirectory: homeDir)
        let report = try manager.enable(on: volumeURL, dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertTrue(report.enabled)
        XCTAssertFalse(report.reset)

        let zshrc = homeDir.appendingPathComponent(".zshrc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: zshrc.path))

        let externalCaches = MacBayPaths.cachesRoot(on: volumeURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalCaches.path))
    }

    func testEnableUpdatesZshrcAndIsIdempotent() throws {
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        try "# Initial config\nalias ll='ls -l'\n".write(to: zshrc, atomically: true, encoding: .utf8)

        let manager = CacheManager(homeDirectory: homeDir)
        let report1 = try manager.enable(on: volumeURL, dryRun: false)
        XCTAssertFalse(report1.dryRun)
        XCTAssertTrue(report1.enabled)

        let content1 = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(content1.contains("alias ll='ls -l'"))
        XCTAssertTrue(content1.contains("# >>> macbay cache >>>"))
        XCTAssertTrue(content1.contains("npm_config_cache"))
        XCTAssertTrue(content1.contains("UV_CACHE_DIR"))
        XCTAssertTrue(content1.contains("GRADLE_USER_HOME"))
        XCTAssertTrue(content1.contains("HF_HOME"))
        XCTAssertTrue(content1.contains("# <<< macbay cache <<<"))

        // Calling enable a second time must NOT duplicate blocks
        let report2 = try manager.enable(on: volumeURL, dryRun: false)
        XCTAssertTrue(report2.enabled)

        let content2 = try String(contentsOf: zshrc, encoding: .utf8)
        let beginCount = content2.components(separatedBy: "# >>> macbay cache >>>").count - 1
        XCTAssertEqual(beginCount, 1)
    }

    func testResetRemovesManagedBlockAndIsIdempotent() throws {
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        try "# Initial config\nalias ll='ls -l'\n".write(to: zshrc, atomically: true, encoding: .utf8)

        let manager = CacheManager(homeDirectory: homeDir)
        _ = try manager.enable(on: volumeURL, dryRun: false)

        let reportReset = try manager.reset(dryRun: false)
        XCTAssertTrue(reportReset.reset)
        XCTAssertFalse(reportReset.enabled)

        let contentAfterReset = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(contentAfterReset.contains("alias ll='ls -l'"))
        XCTAssertFalse(contentAfterReset.contains("# >>> macbay cache >>>"))
        XCTAssertFalse(contentAfterReset.contains("npm_config_cache"))

        // Repeating reset should succeed cleanly
        let reportReset2 = try manager.reset(dryRun: false)
        XCTAssertTrue(reportReset2.reset)
        let contentAfterReset2 = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(contentAfterReset, contentAfterReset2)
    }

    func testExistingSymlinkIsReported() throws {
        let npmDir = homeDir.appendingPathComponent(".npm")
        let dummyTarget = tempDir.appendingPathComponent("custom-npm")
        try FileManager.default.createDirectory(at: dummyTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: npmDir, withDestinationURL: dummyTarget)

        let manager = CacheManager(homeDirectory: homeDir)
        let report = try manager.enable(on: volumeURL, dryRun: false)

        let npmResult = try XCTUnwrap(report.targets.first(where: { $0.name == "npm" }))
        XCTAssertTrue(npmResult.messages.contains { $0.contains("already a symbolic link") })
    }
}
