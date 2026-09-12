import Foundation
import XCTest
@testable import MacBayKit

final class ShellEnvironmentWriterTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        homeDir = tempDir.appendingPathComponent("UserHome")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRCFileGetsGuardedLineAndNoBareExport() throws {
        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("GuardPath")
        let variables = [
            ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: "/Volumes/Ext/npm"),
            ShellEnvironmentWriter.Variable(name: "UV_CACHE_DIR", value: "/Volumes/Ext/uv")
        ]

        let result = try writer.write(variables: variables, guardPath: guardPath)
        XCTAssertEqual(result.guardPath, guardPath.path)

        let zshrc = homeDir.appendingPathComponent(".zshrc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zshrc.path))
        let zshrcContent = try String(contentsOf: zshrc, encoding: .utf8)

        XCTAssertTrue(zshrcContent.contains(ShellEnvironmentWriter.beginMarker))
        XCTAssertTrue(zshrcContent.contains(ShellEnvironmentWriter.endMarker))
        XCTAssertTrue(zshrcContent.contains("[ -d "))
        XCTAssertTrue(zshrcContent.contains("cache-env.sh"))
        XCTAssertFalse(zshrcContent.contains("export npm_config_cache"))
        XCTAssertFalse(zshrcContent.contains("export UV_CACHE_DIR"))

        let envURL = URL(fileURLWithPath: result.environmentFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envURL.path))
        let envContent = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertTrue(envContent.contains("export npm_config_cache='/Volumes/Ext/npm'"))
        XCTAssertTrue(envContent.contains("export UV_CACHE_DIR='/Volumes/Ext/uv'"))
    }

    func testGuardSemanticsWithSh() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
            throw XCTSkip("/bin/sh is not available")
        }

        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("AbsentGuardDir")
        let routedCache = tempDir.appendingPathComponent("RoutedCache").path
        let variables = [
            ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: routedCache)
        ]

        _ = try writer.write(variables: variables, guardPath: guardPath)
        let zshrc = homeDir.appendingPathComponent(".zshrc")

        func runShScript() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ". '\(zshrc.path)'; printf \"%s\" \"$npm_config_cache\""]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        // 1. When guardPath is absent, sourcing the rc file must NOT export npm_config_cache
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardPath.path))
        let outputBeforeGuard = try runShScript()
        XCTAssertEqual(outputBeforeGuard, "", "Variable should not be exported when guard path is absent")

        // 2. When guardPath is created, sourcing the rc file must export npm_config_cache
        try FileManager.default.createDirectory(at: guardPath, withIntermediateDirectories: true)
        let outputAfterGuard = try runShScript()
        XCTAssertEqual(outputAfterGuard, routedCache, "Variable should be exported once guard path exists")
    }

    func testBashrcUpdatedWhenPreCreatedAndBashProfileNotCreatedWhenAbsent() throws {
        let bashrc = homeDir.appendingPathComponent(".bashrc")
        try "# bashrc pre-existing\n".write(to: bashrc, atomically: true, encoding: .utf8)
        let bashProfile = homeDir.appendingPathComponent(".bash_profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bashProfile.path))

        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("GuardPath")
        let result = try writer.write(
            variables: [ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: "/path")],
            guardPath: guardPath
        )

        XCTAssertTrue(result.updatedShellConfigurationPaths.contains(bashrc.path))
        XCTAssertFalse(result.updatedShellConfigurationPaths.contains(bashProfile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bashProfile.path))

        let bashrcContent = try String(contentsOf: bashrc, encoding: .utf8)
        XCTAssertTrue(bashrcContent.contains("# bashrc pre-existing"))
        XCTAssertTrue(bashrcContent.contains(ShellEnvironmentWriter.beginMarker))
        XCTAssertTrue(bashrcContent.contains("cache-env.sh"))
    }

    func testFishConfigFishWhenPreCreated() throws {
        let fishDir = homeDir.appendingPathComponent(".config/fish", isDirectory: true)
        try FileManager.default.createDirectory(at: fishDir, withIntermediateDirectories: true)
        let fishConfigFile = fishDir.appendingPathComponent("config.fish")
        try "# fish config pre-existing\n".write(to: fishConfigFile, atomically: true, encoding: .utf8)

        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("GuardPath")
        let result = try writer.write(
            variables: [ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: "/Volumes/Ext/npm")],
            guardPath: guardPath
        )

        let fishEnvPath = try XCTUnwrap(result.fishEnvironmentFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fishEnvPath))
        let fishEnvContent = try String(contentsOfFile: fishEnvPath, encoding: .utf8)
        XCTAssertTrue(fishEnvContent.contains("set -gx npm_config_cache '/Volumes/Ext/npm'"))

        XCTAssertTrue(result.updatedShellConfigurationPaths.contains(fishConfigFile.path))
        let fishConfigContent = try String(contentsOf: fishConfigFile, encoding: .utf8)
        XCTAssertTrue(fishConfigContent.contains("# fish config pre-existing"))
        XCTAssertTrue(fishConfigContent.contains(ShellEnvironmentWriter.beginMarker))
        XCTAssertTrue(fishConfigContent.contains("test -d "))
        XCTAssertTrue(fishConfigContent.contains("and source "))
        XCTAssertTrue(fishConfigContent.contains("cache-env.fish"))
    }

    func testIdempotencyAcrossThreeWritesAndRemoveRestoresByteForByte() throws {
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        let original = "# Custom header\nalias l='ls -la'\n"
        try original.write(to: zshrc, atomically: true, encoding: .utf8)

        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("GuardPath")
        let variables = [
            ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: "/Volumes/Ext/npm")
        ]

        _ = try writer.write(variables: variables, guardPath: guardPath)
        _ = try writer.write(variables: variables, guardPath: guardPath)
        _ = try writer.write(variables: variables, guardPath: guardPath)

        let contentAfterWrites = try String(contentsOf: zshrc, encoding: .utf8)
        let beginCount = contentAfterWrites.components(separatedBy: ShellEnvironmentWriter.beginMarker).count - 1
        XCTAssertEqual(beginCount, 1)

        let cleaned = try writer.remove()
        XCTAssertTrue(cleaned.contains(zshrc.path))

        let contentAfterRemove = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(contentAfterRemove, original, "remove() must restore original content byte-for-byte")

        let envPath = homeDir.appendingPathComponent(".config/macbay/cache-env.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envPath.path))

        // Repeating remove is idempotent
        let cleanedSecond = try writer.remove()
        XCTAssertFalse(cleanedSecond.contains(zshrc.path))
        let contentAfterSecondRemove = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(contentAfterSecondRemove, original)
    }

    func testUnreadableSecondaryRCFileIsSkippedAndZshrcSucceeds() throws {
        // ~/.bash_profile contains non-UTF8 binary data
        let bashProfile = homeDir.appendingPathComponent(".bash_profile")
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: bashProfile)

        let writer = ShellEnvironmentWriter(homeDirectory: homeDir)
        let guardPath = tempDir.appendingPathComponent("GuardPath")
        let variables = [
            ShellEnvironmentWriter.Variable(name: "npm_config_cache", value: "/Volumes/Ext/npm")
        ]

        // write must succeed and update .zshrc without failing on .bash_profile
        let result = try writer.write(variables: variables, guardPath: guardPath)
        let zshrc = homeDir.appendingPathComponent(".zshrc")
        XCTAssertTrue(result.updatedShellConfigurationPaths.contains(zshrc.path))
        XCTAssertFalse(result.updatedShellConfigurationPaths.contains(bashProfile.path))
        XCTAssertEqual(try Data(contentsOf: bashProfile), Data([0xFF, 0xFE, 0x00, 0x41]))

        // remove must also succeed cleanly without failing on .bash_profile
        let cleaned = try writer.remove()
        XCTAssertTrue(cleaned.contains(zshrc.path))
        XCTAssertFalse(cleaned.contains(bashProfile.path))
        XCTAssertEqual(try Data(contentsOf: bashProfile), Data([0xFF, 0xFE, 0x00, 0x41]))
    }
}
