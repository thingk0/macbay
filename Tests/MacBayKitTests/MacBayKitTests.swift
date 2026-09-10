import Foundation
import XCTest
@testable import MacBayKit

final class MacBayKitTests: XCTestCase {
    func testApplicationNameResolution() {
        XCTAssertEqual(
            MacBayPaths.applicationURL(named: "Aside.app").path,
            "/Applications/Aside.app"
        )
        XCTAssertEqual(
            MacBayPaths.applicationURL(named: "/tmp/Aside.app").path,
            "/tmp/Aside.app"
        )
    }

    func testHumanBytes() {
        XCTAssertEqual(OutputFormatter.humanBytes(0), "0 B")
        XCTAssertEqual(OutputFormatter.humanBytes(1024), "1.0 KB")
        XCTAssertEqual(OutputFormatter.humanBytes(1024 * 1024), "1.0 MB")
    }

    func testSystemCommandRunnerCapturesOutput() throws {
        let result = try SystemCommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf output; printf error >&2"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "output")
        XCTAssertEqual(result.standardError, "error")
    }

    func testProcessInspectorParsesLsofOutput() {
        let output = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 1234 developer cwd DIR 1,1 128 2 /tmp/project with spaces\n"
        XCTAssertEqual(
            ProcessInspector.parseLocks(from: output),
            [ProcessLock(
                process: "node",
                pid: 1234,
                user: "developer",
                fileDescriptor: "cwd",
                path: "/tmp/project with spaces"
            )]
        )
    }

    func testManifestRoundTrip() throws {
        let volume = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: volume) }
        let store = ManifestStore()
        let item = DockedItem(
            name: "Aside.app",
            sourcePath: "/Applications/Aside.app",
            externalPath: volume.appendingPathComponent("MacBay/Applications/Aside.app").path,
            sizeBytes: 1024,
            kind: .application,
            dockedAt: "2026-09-10T00:00:00Z"
        )

        try store.save(DockManifest(items: [item]), on: volume)
        XCTAssertEqual(try store.load(on: volume).items, [item])
    }

    func testScannerFindsApplicationAndCacheCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: app.appendingPathComponent("payload"))
        try Data(repeating: 2, count: 16).write(to: cache.appendingPathComponent("payload"))

        let report = AppScanner().scan(
            minimumApplicationSizeBytes: 16,
            applicationDirectories: [root],
            developerCacheTargets: [DeveloperCacheTarget(name: "Test cache", path: cache)]
        )

        XCTAssertEqual(report.candidates.map(\.name), ["Example.app", "Test cache"])
        XCTAssertEqual(report.candidates.map(\.kind), [.application, .developerCache])
    }

    func testDirectoryMigratorDryRunDoesNotChangeFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("MacBay/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("file.txt"))

        let runner = StubCommandRunner()
        runner.result = CommandResult(status: 1)
        let migrator = DirectoryMigrator(commandRunner: runner)
        let result = try migrator.migrate(
            source: source,
            destination: destination,
            operation: "test",
            dryRun: true
        )

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSQLiteSidecarIsReportedAsUnsafe() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.sqlite")
        try Data().write(to: database)
        try Data().write(to: URL(fileURLWithPath: database.path + "-wal"))

        let runner = StubCommandRunner()
        runner.result = CommandResult(status: 1)
        let inspection = try ProcessInspector(commandRunner: runner).inspect(path: root)

        XCTAssertFalse(inspection.isSafeToMove)
        XCTAssertEqual(inspection.sqliteLocks.count, 1)
        XCTAssertTrue(inspection.sqliteLocks[0].databasePath.hasSuffix(database.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class StubCommandRunner: CommandRunner, @unchecked Sendable {
    var result = CommandResult(status: 0)
    var calls: [(String, [String])] = []

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        calls.append((executable, arguments))
        return result
    }
}
