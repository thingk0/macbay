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
        XCTAssertTrue(content1.contains("[ -d "))
        XCTAssertTrue(content1.contains("cache-env.sh"))
        XCTAssertTrue(content1.contains("# <<< macbay cache <<<"))

        let envPath = try XCTUnwrap(report1.environmentFilePath)
        let envContent1 = try String(contentsOfFile: envPath, encoding: .utf8)
        XCTAssertTrue(envContent1.contains("npm_config_cache"))
        XCTAssertTrue(envContent1.contains("UV_CACHE_DIR"))
        XCTAssertTrue(envContent1.contains("GRADLE_USER_HOME"))
        XCTAssertTrue(envContent1.contains("HF_HOME"))

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
        let report = try manager.enable(on: volumeURL, dryRun: false)
        let envPath = try XCTUnwrap(report.environmentFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envPath))

        let reportReset = try manager.reset(dryRun: false)
        XCTAssertTrue(reportReset.reset)
        XCTAssertFalse(reportReset.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envPath))

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

    func testEnableRefusesToOverwriteUnreadableZshrc() throws {
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        // UTF-8로 해석되지 않는 바이트: 읽기 실패를 빈 파일로 취급하면 안 된다.
        try Data([0xFF, 0xFE, 0x41]).write(to: zshrc)

        let manager = CacheManager(homeDirectory: homeDir)
        XCTAssertThrowsError(try manager.enable(on: volumeURL, dryRun: false))

        let after = try Data(contentsOf: zshrc)
        XCTAssertEqual(after, Data([0xFF, 0xFE, 0x41]))
    }

    func testExternalPathIsShellQuoted() throws {
        let trickyVolume = tempDir.appendingPathComponent("Ext $(echo pwned) `id` it's")
        try FileManager.default.createDirectory(at: trickyVolume, withIntermediateDirectories: true)

        let manager = CacheManager(homeDirectory: homeDir)
        let report = try manager.enable(on: trickyVolume, dryRun: false)

        let envPath = try XCTUnwrap(report.environmentFilePath)
        let envContent = try String(contentsOfFile: envPath, encoding: .utf8)
        XCTAssertFalse(envContent.contains("export HF_HOME=\""))
        XCTAssertTrue(envContent.contains("export HF_HOME='"))
        XCTAssertTrue(envContent.contains("it'\\''s"))

        let zshrcContent = try String(contentsOf: homeDir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrcContent.contains("it'\\''s"))
        XCTAssertEqual(CacheManager.shellQuoted("a'b"), "'a'\\''b'")
    }

    func testSymlinkedZshrcIsPreservedAsLink() throws {
        let dotfiles = tempDir.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("zshrc")
        try "alias ll='ls -l'\n".write(to: real, atomically: true, encoding: .utf8)
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(atPath: zshrc.path, withDestinationPath: real.path)

        let manager = CacheManager(homeDirectory: homeDir)
        _ = try manager.enable(on: volumeURL, dryRun: false)

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path))
        let realContent = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(realContent.contains("alias ll='ls -l'"))
        XCTAssertTrue(realContent.contains("# >>> macbay cache >>>"))

        _ = try manager.reset(dryRun: false)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path))
        let afterReset = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(afterReset.contains("alias ll='ls -l'"))
        XCTAssertFalse(afterReset.contains("# >>> macbay cache >>>"))
    }

    func testCacheReportBackwardCompatibleDecode() throws {
        let legacyJSON = """
        {
            "enabled": true,
            "reset": false,
            "targets": [],
            "shellConfigurationPath": "/Users/test/.zshrc",
            "dryRun": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CacheReport.self, from: legacyJSON)
        XCTAssertTrue(decoded.enabled)
        XCTAssertFalse(decoded.reset)
        XCTAssertEqual(decoded.shellConfigurationPath, "/Users/test/.zshrc")
        XCTAssertEqual(decoded.shellConfigurationPaths, ["/Users/test/.zshrc"])
        XCTAssertNil(decoded.environmentFilePath)
        XCTAssertNil(decoded.guardPath)
        XCTAssertFalse(decoded.dryRun)
    }

    func testCacheReportRoundTripWithNewFields() throws {
        let report = CacheReport(
            enabled: true,
            reset: false,
            targets: [],
            shellConfigurationPath: "/Users/test/.zshrc",
            shellConfigurationPaths: ["/Users/test/.zshrc", "/Users/test/.bashrc"],
            environmentFilePath: "/Users/test/.config/macbay/cache-env.sh",
            guardPath: "/Volumes/Ext/MacBay/Caches",
            dryRun: false
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CacheReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
