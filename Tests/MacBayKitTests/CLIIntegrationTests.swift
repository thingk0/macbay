import Foundation
import XCTest
@testable import MacBayKit

final class CLIIntegrationTests: XCTestCase {
    private var binaryURL: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("mb")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("mb")
    }

    private func runCLI(arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    func testVersionOutput() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("1.0.0"))
    }

    func testHelpOutputMentionsSubcommands() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("status"))
        XCTAssertTrue(result.stdout.contains("scan"))
        XCTAssertTrue(result.stdout.contains("dock"))
        XCTAssertTrue(result.stdout.contains("undock"))
        XCTAssertTrue(result.stdout.contains("xcode"))
        XCTAssertTrue(result.stdout.contains("cache"))
        XCTAssertFalse(result.stdout.contains("clean"))
    }

    func testCleanCommandIsRejectedAsUnknown() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["clean"])
        XCTAssertNotEqual(result.status, 0)
    }

    func testStatusJsonSchema() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["status", "--json"])
        XCTAssertEqual(result.status, 0)
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }

        XCTAssertNotNil(json["internalVolume"])
        XCTAssertNotNil(json["externalVolumes"] as? [[String: Any]])
        XCTAssertNotNil(json["dockedItems"] as? [[String: Any]])
        XCTAssertNotNil(json["warnings"] as? [String])
    }

    func testScanJsonSchema() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["scan", "--json"])
        XCTAssertEqual(result.status, 0)
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }

        XCTAssertNotNil(json["generatedAt"] as? String)
        XCTAssertNotNil(json["minimumApplicationSizeBytes"] as? NSNumber)
        XCTAssertNotNil(json["candidates"] as? [[String: Any]])
        XCTAssertNotNil(json["externalApplications"] as? [[String: Any]])
        XCTAssertNotNil(json["unresolvedApplicationLinks"] as? [[String: Any]])
        XCTAssertNotNil(json["warnings"] as? [String])
    }

    func testScanHelpMentionsExternalApps() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["scan", "--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("externalized"))
    }

    func testMutatingCommandJsonErrorEnvelope() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        // dock non-existent app in dry-run with --json
        let result = try runCLI(arguments: ["dock", "DefinitelyNonExistentApp12345.app", "--dry-run", "--json"])
        XCTAssertNotEqual(result.status, 0)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertEqual(errorObj["code"] as? String, "configuration_error")
        XCTAssertNotNil(errorObj["message"] as? String)
        XCTAssertNotNil(errorObj["details"] as? String)
    }

    func testRemovedDryRunOptionOnStatusFails() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        // --dry-run was removed from status in v0.2.0
        let result = try runCLI(arguments: ["status", "--dry-run"])
        XCTAssertNotEqual(result.status, 0)
    }

    func testStatusPipedOutputHasNoAnsi() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["status"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("MacBay storage status"))
        XCTAssertTrue(result.stdout.contains("Internal ·"))
        // Piped subprocess should not have ANSI escape codes
        XCTAssertFalse(result.stdout.contains("\u{001B}"))
    }

    func testStatusWithNoColorEnvHasNoAnsi() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        let result = try runCLI(arguments: ["status"], environment: env)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.stdout.contains("\u{001B}"))
    }

    func testStatusWithTermDumbHasNoAnsi() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        let result = try runCLI(arguments: ["status"], environment: env)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.stdout.contains("\u{001B}"))
    }
}
