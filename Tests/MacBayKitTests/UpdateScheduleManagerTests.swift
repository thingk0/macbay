import Foundation
import XCTest
@testable import MacBayKit

final class UpdateScheduleManagerTests: XCTestCase {
    private var root: URL!
    private var manager: UpdateScheduleManager!
    private var runner: UpdateScheduleTestCommandRunner!
    private var executable: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        executable = root.appendingPathComponent("bin/mb")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        runner = UpdateScheduleTestCommandRunner()
        manager = UpdateScheduleManager(
            commandRunner: runner,
            homeDirectory: home,
            uid: 501
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScheduleStartsDisabledAndEnablesDailyAtFour() throws {
        XCTAssertFalse(try manager.status().enabled)

        let enabled = try manager.enable(executablePath: executable.path)

        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.hour, 4)
        XCTAssertEqual(enabled.minute, 0)
        let plist = try readAgent()
        XCTAssertEqual(plist["Label"] as? String, UpdateScheduleManager.launchAgentLabel)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            executable.path, "update", "run", "Kiro CLI.app", "--yes", "--scheduled", "--json"
        ])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Hour": 4, "Minute": 0])
        XCTAssertNil(plist["RunAtLoad"])
        XCTAssertTrue(runner.loaded)
    }

    func testStatusReportsUnloadedAgentAsDisabled() throws {
        _ = try manager.enable(executablePath: executable.path)
        runner.loaded = false

        XCTAssertFalse(try manager.status().enabled)
    }

    func testDisableUnloadsAndRemovesMacBayAgent() throws {
        _ = try manager.enable(executablePath: executable.path)

        let disabled = try manager.disable()

        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(runner.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabled.launchAgentPath))
    }

    func testDisableCleansOwnedAgentEvenIfStateFileIsMissing() throws {
        let path = try manager.status().launchAgentPath
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": UpdateScheduleManager.launchAgentLabel], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        runner.loaded = true

        let result = try manager.disable()

        XCTAssertFalse(result.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(runner.loaded)
    }

    func testBuildPathCannotBeScheduled() throws {
        let buildBinary = root.appendingPathComponent(".build/release/mb")
        try FileManager.default.createDirectory(at: buildBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: buildBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: buildBinary.path)

        XCTAssertThrowsError(try manager.enable(executablePath: buildBinary.path))
        XCTAssertFalse(try manager.status().enabled)
    }

    func testBootstrapFailureRestoresPriorAgentAndState() throws {
        let original = try manager.enable(executablePath: executable.path, hour: 5, minute: 30)
        let originalData = try Data(contentsOf: URL(fileURLWithPath: original.launchAgentPath))
        let replacement = root.appendingPathComponent("other/mb")
        try FileManager.default.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        runner.bootstrapStatus = 72

        XCTAssertThrowsError(try manager.enable(executablePath: replacement.path, hour: 6))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.launchAgentPath)), originalData)
        XCTAssertFalse(try manager.status().enabled)
        XCTAssertFalse(runner.loaded)
    }

    func testForeignLaunchAgentIsNotOverwrittenOrRemoved() throws {
        let path = try manager.status().launchAgentPath
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "example.foreign"], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try manager.enable(executablePath: executable.path))
        XCTAssertThrowsError(try manager.disable())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
    }

    private func readAgent() throws -> [String: Any] {
        let path = try manager.status().launchAgentPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }
}

private final class UpdateScheduleTestCommandRunner: CommandRunner, @unchecked Sendable {
    var loaded = false
    var bootstrapStatus: Int32 = 0
    var bootoutStatus: Int32 = 0

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        guard executable == "/bin/launchctl", let command = arguments.first else {
            return CommandResult(status: 0)
        }
        switch command {
        case "print":
            return CommandResult(status: loaded ? 0 : 1)
        case "bootstrap":
            if bootstrapStatus == 0 { loaded = true }
            return CommandResult(status: bootstrapStatus, standardError: "bootstrap failed")
        case "bootout":
            if bootoutStatus == 0 { loaded = false }
            return CommandResult(status: bootoutStatus, standardError: "bootout failed")
        default:
            return CommandResult(status: 0)
        }
    }
}
