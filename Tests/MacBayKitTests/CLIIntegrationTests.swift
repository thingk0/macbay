import Darwin
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

    private var fixtureDirectories: [URL] = []
    private var manifestEntriesToClean: [(volumeURL: URL, appName: String)] = []

    override func tearDownWithError() throws {
        for entry in manifestEntriesToClean {
            let manifestStore = ManifestStore()
            try? manifestStore.updating(on: entry.volumeURL) { manifest in
                manifest.items.removeAll { $0.name == entry.appName }
            }
        }
        manifestEntriesToClean.removeAll()

        for url in fixtureDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureDirectories.removeAll()
    }

    /// A throwaway applications directory holding one small bundle.
    ///
    /// The scan tests used to walk the real /Applications. On a machine with large
    /// bundles installed that took about a minute per test, which dominated the
    /// whole suite; a fixture keeps the same code path but makes the walk trivial.
    private func makeApplicationsFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbay-scan-fixture-\(UUID().uuidString)", isDirectory: true)
        let executables = root
            .appendingPathComponent("Fixture.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: executables.appendingPathComponent("Fixture"))
        fixtureDirectories.append(root)
        return root
    }

    private func runCLI(
        arguments: [String],
        environment: [String: String]? = nil,
        closeStdin: Bool = false
    ) throws -> (status: Int32, stdout: String, stderr: String) {
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

        if closeStdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try stdinPipe.fileHandleForWriting.close()
        }

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func makeConfigHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayCLIConfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Isolated HOME so tests never depend on the developer's real dotfiles.
    private func makeIsolatedHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayCLIHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        fixtureDirectories.append(url)
        return url
    }

    private func configEnvironment(_ configHome: URL, home: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = configHome.path
        if let home {
            environment["HOME"] = home.path
        }
        return environment
    }

    private func configFilePath(in configHome: URL) -> String {
        configHome.appendingPathComponent("macbay/config.json").path
    }

    func testVersionOutput() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains(MacBayVersion.current))
    }

    func testHelpOutputMentionsSubcommands() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("status"))
        XCTAssertTrue(result.stdout.contains("scan"))
        XCTAssertTrue(result.stdout.contains("doctor"))
        XCTAssertTrue(result.stdout.contains("dock"))
        XCTAssertTrue(result.stdout.contains("adopt"))
        XCTAssertTrue(result.stdout.contains("undock"))
        XCTAssertTrue(result.stdout.contains("repair"))
        XCTAssertTrue(result.stdout.contains("xcode"))
        XCTAssertTrue(result.stdout.contains("move"))
        XCTAssertTrue(result.stdout.contains("unmove"))
        XCTAssertTrue(result.stdout.contains("cache"))
        XCTAssertTrue(result.stdout.contains("teardown"))
        XCTAssertTrue(result.stdout.contains("init"))
        XCTAssertTrue(result.stdout.contains("Choose and save the default external volume"))
        XCTAssertFalse(result.stdout.contains("clean"))
    }

    func testAdoptHelpOutput() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["adopt", "--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Adopt an externally located application"))
        XCTAssertTrue(result.stdout.contains("--dry-run"))
        XCTAssertTrue(result.stdout.contains("--force"))
        XCTAssertTrue(result.stdout.contains("--json"))
        XCTAssertTrue(result.stdout.contains("--yes"))
    }

    func testAdoptNonExistentAppJsonError() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["adopt", "DefinitelyMissingApp.app", "--volume", "/Volumes/ExternalSSD", "--json"])
        XCTAssertNotEqual(result.status, 0)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertEqual(errorObj["code"] as? String, "configuration_error")
        XCTAssertNotNil(errorObj["message"] as? String)
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

        let applications = try makeApplicationsFixture()
        let result = try runCLI(arguments: ["scan", "--json", "--applications-dir", applications.path])
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

    func testScanVerboseExecution() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let applications = try makeApplicationsFixture()
        let result = try runCLI(arguments: ["scan", "--verbose", "--applications-dir", applications.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("MacBay scan"))
    }

    func testScanJsonWithVerboseOutputsPureJson() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let applications = try makeApplicationsFixture()
        let result = try runCLI(arguments: ["scan", "--json", "--verbose", "--applications-dir", applications.path])
        XCTAssertEqual(result.status, 0)
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON when --json --verbose were passed: \(result.stdout)")
        }
        XCTAssertNotNil(json["candidates"])
    }

    func testDoctorJsonSchema() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let configHome = try makeConfigHome()
        defer {
            try? FileManager.default.removeItem(at: configHome)
        }

        let result = try runCLI(
            arguments: ["doctor", "--json"],
            environment: configEnvironment(configHome, home: home)
        )
        XCTAssertTrue([0, 1].contains(result.status), "unexpected exit code \(result.status)")

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }

        XCTAssertNotNil(json["generatedAt"] as? String)
        XCTAssertNotNil(json["volumes"] as? [[String: Any]])
        XCTAssertNotNil(json["findings"] as? [[String: Any]])
        XCTAssertNotNil(json["summary"] as? [String: Any])
        XCTAssertNotNil(json["warnings"] as? [String])
        XCTAssertNotNil(json["notes"] as? [String])
        XCTAssertNil(json["exitCode"])
    }

    func testDoctorHumanOutputIsReadOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let configHome = try makeConfigHome()
        defer {
            try? FileManager.default.removeItem(at: configHome)
        }

        let result = try runCLI(
            arguments: ["doctor"],
            environment: configEnvironment(configHome, home: home)
        )
        XCTAssertTrue([0, 1].contains(result.status), "unexpected exit code \(result.status)")
        XCTAssertTrue(result.stdout.contains("MacBay doctor"))
        XCTAssertFalse(result.stdout.contains("\u{001B}"))
    }

    func testDoctorRejectsDryRunOption() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["doctor", "--dry-run"])
        XCTAssertNotEqual(result.status, 0)
    }

    func testDoctorWithUnknownVolumeExitsTwo() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["doctor", "--volume", "/DefinitelyMissingVolume", "--json"])
        XCTAssertEqual(result.status, 2)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertEqual(errorObj["code"] as? String, "configuration_error")
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testInitShowJsonReportsNoDefault() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let configHome = try makeConfigHome()
        defer { try? FileManager.default.removeItem(at: configHome) }

        let result = try runCLI(
            arguments: ["init", "--show", "--json"],
            environment: configEnvironment(configHome)
        )
        XCTAssertEqual(result.status, 0)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }

        XCTAssertEqual(json["configPath"] as? String, configFilePath(in: configHome))
        XCTAssertTrue(json["defaultVolume"] == nil || json["defaultVolume"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFilePath(in: configHome)))
    }

    func testInitResetWithoutSavedDefaultIsNoOp() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let configHome = try makeConfigHome()
        defer { try? FileManager.default.removeItem(at: configHome) }

        let result = try runCLI(
            arguments: ["init", "--reset", "--json"],
            environment: configEnvironment(configHome)
        )
        XCTAssertEqual(result.status, 0)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }

        XCTAssertEqual(json["configPath"] as? String, configFilePath(in: configHome))
        XCTAssertTrue(json["removedVolume"] == nil || json["removedVolume"] is NSNull)
    }

    func testInitRejectsCombinedModes() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let showAndReset = try runCLI(arguments: ["init", "--show", "--reset"])
        XCTAssertNotEqual(showAndReset.status, 0)

        let volumeAndShow = try runCLI(arguments: ["init", "--volume", "/Volumes/Example", "--show"])
        XCTAssertNotEqual(volumeAndShow.status, 0)
    }

    func testInitWithUnknownVolumeReportsJsonError() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let configHome = try makeConfigHome()
        defer { try? FileManager.default.removeItem(at: configHome) }

        let result = try runCLI(
            arguments: ["init", "--volume", "/DefinitelyMissingVolume", "--json"],
            environment: configEnvironment(configHome)
        )
        XCTAssertNotEqual(result.status, 0)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertNotNil(errorObj["code"] as? String)
        XCTAssertNotNil(errorObj["message"] as? String)
        XCTAssertNotNil(errorObj["details"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFilePath(in: configHome)))
    }

    func testInitWithClosedStdinIsNotInteractive() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let configHome = try makeConfigHome()
        defer { try? FileManager.default.removeItem(at: configHome) }

        let result = try runCLI(
            arguments: ["init"],
            environment: configEnvironment(configHome),
            closeStdin: true
        )

        if result.status == 0 {
            XCTAssertTrue(result.stdout.contains("MacBay default volume"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: configFilePath(in: configHome)))
        } else {
            XCTAssertFalse(result.stderr.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: configFilePath(in: configHome)))
        }
    }

    private func firstWritableExternalVolume() throws -> StorageVolume? {
        let manager = VolumeManager()
        return try manager.externalVolumes().first
    }

    private func makeExternalAppFixture(
        on volumeURL: URL,
        appName: String = "TestApp.app",
        isPopupRisk: Bool = false
    ) throws -> (appURL: URL, symlinkURL: URL) {
        let baseDir = volumeURL.appendingPathComponent("macbay-test-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        fixtureDirectories.append(baseDir)

        let appURL = baseDir.appendingPathComponent(appName, isDirectory: true)
        let macosDir = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        let execURL = macosDir.appendingPathComponent("TestApp")
        try "#!/bin/sh\nexit 0\n".write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let extraPlist = isPopupRisk ? "<key>SMPrivilegedExecutables</key><dict><key>com.example.helper</key><string>identifier</string></dict>" : ""
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>TestApp</string>
            <key>CFBundleIdentifier</key>
            <string>com.example.macbay.test</string>
            <key>CFBundleName</key>
            <string>TestApp</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            \(extraPlist)
        </dict>
        </plist>
        """
        try plistContent.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let signProcess = Process()
        signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProcess.arguments = ["-s", "-", "--force", appURL.path]
        try signProcess.run()
        signProcess.waitUntilExit()

        let symlinkParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbay-symlinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
        fixtureDirectories.append(symlinkParent)

        let symlinkURL = symlinkParent.appendingPathComponent(appName)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: appURL)

        return (appURL, symlinkURL)
    }

    func testAdoptDryRunOutputsPlanAndDoesNotMutateFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (appURL, symlinkURL) = try makeExternalAppFixture(on: volumeURL, appName: "CLIAdoptDryRun.app")

        let result = try runCLI(arguments: ["adopt", symlinkURL.path, "--volume", volume.path, "--dry-run"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Dry run: adopt CLIAdoptDryRun.app"))
        XCTAssertTrue(result.stdout.contains("Dry run: no files were changed"))

        // Verify no files were moved
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        let macbayDest = volumeURL.appendingPathComponent("MacBay/Applications/CLIAdoptDryRun.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: macbayDest.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path), appURL.path)
    }

    func testAdoptJsonWithoutYesFailsWithConfirmationRequired() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (appURL, symlinkURL) = try makeExternalAppFixture(on: volumeURL, appName: "CLIAdoptJsonNoYes.app")

        let result = try runCLI(arguments: ["adopt", symlinkURL.path, "--volume", volume.path, "--json"])
        XCTAssertNotEqual(result.status, 0)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertEqual(errorObj["code"] as? String, "configuration_error")
        let message = errorObj["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Confirmation required"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    func testAdoptReviewRequiredWithoutForceFailsWithoutPrompting() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (_, symlinkURL) = try makeExternalAppFixture(on: volumeURL, appName: "CLIAdoptReview.app", isPopupRisk: true)

        let result = try runCLI(
            arguments: ["adopt", symlinkURL.path, "--volume", volume.path],
            closeStdin: true
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Review required · CLIAdoptReview.app"))
        XCTAssertTrue(result.stdout.contains("mb adopt \"CLIAdoptReview.app\" --force"))
        XCTAssertTrue(result.stdout.contains("No files were changed"))
        XCTAssertFalse(result.stdout.contains("Proceed with adoption?"))
    }

    func testAdoptReviewRequiredWithForceAndDryRun() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (_, symlinkURL) = try makeExternalAppFixture(on: volumeURL, appName: "CLIAdoptReviewForce.app", isPopupRisk: true)

        let result = try runCLI(
            arguments: ["adopt", symlinkURL.path, "--volume", volume.path, "--force", "--dry-run"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Notice: Proceeding with --force"))
        XCTAssertTrue(result.stdout.contains("Dry run: adopt CLIAdoptReviewForce.app"))
    }

    func testRepairHelpOutput() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["repair", "--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Compare duplicate local/external application copies"))
        XCTAssertTrue(result.stdout.contains("--action"))
        XCTAssertTrue(result.stdout.contains("--rollback"))
        XCTAssertTrue(result.stdout.contains("--dry-run"))
        XCTAssertTrue(result.stdout.contains("--json"))
        XCTAssertTrue(result.stdout.contains("--yes"))
    }

    private func makeDuplicateAppFixture(
        on volumeURL: URL,
        appName: String = "CLIDuplicateApp.app"
    ) throws -> (localAppURL: URL, externalAppURL: URL) {
        let baseDir = volumeURL.appendingPathComponent("macbay-test-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        fixtureDirectories.append(baseDir)

        let appsDir = baseDir.appendingPathComponent("MacBay/Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let externalAppURL = appsDir.appendingPathComponent(appName, isDirectory: true)

        let macosDirExt = externalAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDirExt, withIntermediateDirectories: true)
        let execURLExt = macosDirExt.appendingPathComponent("App")
        try "#!/bin/sh\nexit 0\n".write(to: execURLExt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURLExt.path)

        let plistExt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>App</string>
            <key>CFBundleIdentifier</key>
            <string>com.example.duplicate</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0.0</string>
            <key>CFBundleVersion</key>
            <string>100</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plistExt.write(to: externalAppURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let signProcessExt = Process()
        signProcessExt.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProcessExt.arguments = ["-s", "-", "--force", externalAppURL.path]
        try signProcessExt.run()
        signProcessExt.waitUntilExit()

        let localParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbay-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localParent, withIntermediateDirectories: true)
        fixtureDirectories.append(localParent)

        let localAppURL = localParent.appendingPathComponent(appName, isDirectory: true)
        let macosDirLoc = localAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDirLoc, withIntermediateDirectories: true)
        let execURLLoc = macosDirLoc.appendingPathComponent("App")
        try "#!/bin/sh\nexit 0\n".write(to: execURLLoc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURLLoc.path)

        let plistLoc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>App</string>
            <key>CFBundleIdentifier</key>
            <string>com.example.duplicate</string>
            <key>CFBundleShortVersionString</key>
            <string>1.2.0</string>
            <key>CFBundleVersion</key>
            <string>120</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plistLoc.write(to: localAppURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let signProcessLoc = Process()
        signProcessLoc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProcessLoc.arguments = ["-s", "-", "--force", localAppURL.path]
        try signProcessLoc.run()
        signProcessLoc.waitUntilExit()

        let manifestStore = ManifestStore()
        try manifestStore.updating(on: volumeURL) { manifest in
            manifest.items.removeAll { $0.name == appName || $0.sourcePath == localAppURL.path }
            manifest.items.append(DockedItem(
                name: appName,
                sourcePath: localAppURL.path,
                externalPath: externalAppURL.path,
                sizeBytes: 1024,
                kind: .application,
                dockedAt: "2026-09-01T00:00:00Z"
            ))
        }
        manifestEntriesToClean.append((volumeURL: volumeURL, appName: appName))

        return (localAppURL, externalAppURL)
    }

    func testRepairComparisonReadOnlyOutputsComparison() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (localURL, externalURL) = try makeDuplicateAppFixture(on: volumeURL, appName: "CLIRepairCompare.app")

        let result = try runCLI(arguments: ["repair", localURL.path, "--volume", volume.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Repair comparison · CLIRepairCompare.app"))
        XCTAssertTrue(result.stdout.contains("Available actions:"))
        XCTAssertTrue(result.stdout.contains("--action redock"))
        XCTAssertTrue(result.stdout.contains("--action keep-local"))

        // Verify files were not modified
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testRepairRedockDryRunOutputsPlanAndDoesNotMutateFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (localURL, externalURL) = try makeDuplicateAppFixture(on: volumeURL, appName: "CLIRepairRedockDryRun.app")

        let result = try runCLI(
            arguments: ["repair", localURL.path, "--action", "redock", "--volume", volume.path, "--dry-run"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Dry run: repair CLIRepairRedockDryRun.app (redock)"))
        XCTAssertTrue(result.stdout.contains("Dry run: no files were changed"))

        // Verify files were not moved
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testRepairKeepLocalDryRunOutputsPlan() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (localURL, externalURL) = try makeDuplicateAppFixture(on: volumeURL, appName: "CLIRepairKeepLocalDryRun.app")

        let result = try runCLI(
            arguments: ["repair", localURL.path, "--action", "keep-local", "--volume", volume.path, "--dry-run"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Dry run: repair CLIRepairKeepLocalDryRun.app (keep-local)"))
        XCTAssertTrue(result.stdout.contains("Dry run: no files were changed"))

        // Verify files were not moved
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testRepairRedockJsonWithoutYesFailsWithConfirmationRequired() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }
        guard let volume = try firstWritableExternalVolume() else {
            throw XCTSkip("No writable external volume available for integration test")
        }

        let volumeURL = URL(fileURLWithPath: volume.path)
        let (localURL, _) = try makeDuplicateAppFixture(on: volumeURL, appName: "CLIRepairJsonNoYes.app")

        let result = try runCLI(
            arguments: ["repair", localURL.path, "--action", "redock", "--volume", volume.path, "--json"]
        )
        XCTAssertNotEqual(result.status, 0)

        guard let data = result.stderr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return XCTFail("stderr was not valid error JSON envelope: \(result.stderr)")
        }

        XCTAssertEqual(errorObj["code"] as? String, "configuration_error")
        let message = errorObj["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Confirmation required"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testZeroArgumentNonTTYOutputsHelpAndExitsZero() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: [])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("status"))
        XCTAssertTrue(result.stdout.contains("tui"))
        XCTAssertFalse(result.stdout.contains("\u{001B}"))
    }

    func testTUICommandNonTTYFailsWithExplanation() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["tui"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Interactive terminal required for TUI mode"))
    }

    func testJsonOutputContainsNoControlCharacters() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let statusResult = try runCLI(arguments: ["status", "--json"])
        XCTAssertEqual(statusResult.status, 0)
        XCTAssertFalse(statusResult.stdout.contains("\u{001B}"))
        XCTAssertFalse(statusResult.stderr.contains("\u{001B}"))

        let applications = try makeApplicationsFixture()
        let scanResult = try runCLI(arguments: ["scan", "--json", "--applications-dir", applications.path])
        XCTAssertEqual(scanResult.status, 0)
        XCTAssertFalse(scanResult.stdout.contains("\u{001B}"))
        XCTAssertFalse(scanResult.stderr.contains("\u{001B}"))

        let doctorHome = try makeIsolatedHome()
        let doctorConfigHome = try makeConfigHome()
        defer {
            try? FileManager.default.removeItem(at: doctorConfigHome)
        }
        let doctorResult = try runCLI(
            arguments: ["doctor", "--json"],
            environment: configEnvironment(doctorConfigHome, home: doctorHome)
        )
        XCTAssertFalse(doctorResult.stdout.contains("\u{001B}"))
        XCTAssertFalse(doctorResult.stderr.contains("\u{001B}"))
    }

    func testDoctorRejectsReferencePathFlag() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["doctor", "--reference-path", "/tmp/custom.json"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertNotEqual(result.status, 1)
    }

    func testDoctorIgnoresHistoryFilesWithMissingAppPaths() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let configHome = try makeConfigHome()
        defer { try? FileManager.default.removeItem(at: configHome) }

        let history = home.appendingPathComponent(".zsh_history")
        var lines: [String] = []
        for index in 0..<300 {
            lines.append(": 1787399273:0;open /Volumes/NoSuchVolume/deno.app/Contents/\(index)")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: history)

        let result = try runCLI(
            arguments: ["doctor", "--json"],
            environment: configEnvironment(configHome, home: home)
        )
        XCTAssertEqual(result.status, 0, "Home history must not affect doctor: \(result.stdout)")

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = json["findings"] as? [[String: Any]] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }
        XCTAssertTrue(findings.filter { ($0["category"] as? String) == "external_reference" }.isEmpty)
    }

    func testHelpOutputMentionsReferences() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("references"))
    }

    func testReferencesRequiresPath() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let result = try runCLI(arguments: ["references", "--json"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertNotEqual(result.status, 1)
    }

    func testReferencesRejectsDirectory() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let directory = home.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = try runCLI(arguments: ["references", "--json", "--path", directory.path])
        XCTAssertEqual(result.status, 1)
    }

    func testReferencesRejectsFIFOAndSymlinkWithoutBlocking() throws {
        let home = try makeIsolatedHome()
        let fifo = home.appendingPathComponent("settings.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let link = home.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)

        for path in [fifo, link] {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["references", "--json", "--path", path.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            let exited = expectation(description: "Reject \(path.lastPathComponent) promptly")
            process.terminationHandler = { _ in exited.fulfill() }
            try process.run()
            let result = XCTWaiter.wait(for: [exited], timeout: 5)
            if result != .completed {
                process.terminate()
                process.waitUntilExit()
                XCTFail("references blocked on a FIFO input")
                continue
            }
            XCTAssertEqual(process.terminationStatus, 1)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let report = try JSONDecoder().decode(ReferenceReport.self, from: data)
            XCTAssertTrue(report.findings.contains {
                $0.code == .externalConfigUnreadable && $0.detail.contains("not a regular file")
            })
        }
    }

    func testReferencesReportsMissingFile() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayMissing-\(UUID().uuidString).json").path

        let result = try runCLI(arguments: ["references", "--json", "--path", missing])
        XCTAssertEqual(result.status, 1)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = json["findings"] as? [[String: Any]] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }
        XCTAssertTrue(findings.contains { ($0["code"] as? String) == "external_config_unreadable" })
        XCTAssertNotNil(json["generatedAt"] as? String)
        XCTAssertNotNil(json["notes"])
        XCTAssertNil(json["exitCode"])
    }

    func testReferencesChecksSpecifiedFilesOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let checked = home.appendingPathComponent("checked.json")
        let neighbour = home.appendingPathComponent("neighbour.json")
        let payload = "{ \"bin\": \"/opt/previous/MacBayCLIFixture.app/Contents/MacOS/tool\" }"
        try Data(payload.utf8).write(to: checked)
        try Data(payload.utf8).write(to: neighbour)

        let result = try runCLI(arguments: ["references", "--json", "--path", checked.path])
        XCTAssertEqual(result.status, 1)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = json["findings"] as? [[String: Any]],
              let finding = findings.first(where: { ($0["code"] as? String) == "external_reference_missing" }) else {
            return XCTFail("Missing finding: \(result.stdout)")
        }
        XCTAssertEqual(finding["name"] as? String, "MacBayCLIFixture.app")
        XCTAssertEqual((finding["paths"] as? [String])?.first, checked.path)
        XCTAssertEqual(finding["referenceLocations"] as? [String], ["bin"])
        XCTAssertTrue((json["notes"] as? [String] ?? []).contains { $0.contains("Only the files passed with --path were read") })
    }

    func testReferencesDedupesRepeatedPaths() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let file = home.appendingPathComponent("tool.json")
        try Data("{ \"bin\": \"/opt/previous/MacBayCLIFixture.app/Contents/MacOS/tool\" }".utf8).write(to: file)

        let result = try runCLI(
            arguments: ["references", "--json", "--path", file.path, "--path", file.path]
        )
        XCTAssertEqual(result.status, 1)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = json["findings"] as? [[String: Any]] else {
            return XCTFail("stdout was not valid JSON: \(result.stdout)")
        }
        XCTAssertEqual(findings.filter { ($0["code"] as? String) == "external_reference_missing" }.count, 1)
    }

    func testReferencesReportsHealthyWhenPathExists() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let file = home.appendingPathComponent("tool.json")
        try Data("{ \"bin\": \"/bin/sh\" }".utf8).write(to: file)

        let missingApp = home.appendingPathComponent("OldApps/MacBayCLIFixture.app/Contents/MacOS/tool")
        try FileManager.default.createDirectory(at: missingApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: home.appendingPathComponent("existing.json"))
        _ = missingApp

        let result = try runCLI(arguments: ["references", "--json", "--path", file.path])
        XCTAssertEqual(result.status, 0, "\(result.stdout) \(result.stderr)")
    }

    func testReferencesReportsCandidateAndReadLimit() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let home = try makeIsolatedHome()
        let file = home.appendingPathComponent("tool.json")
        try Data("{ \"bin\": \"/opt/previous/MacBayCLIFixture.app/Contents/MacOS/tool\" }".utf8).write(to: file)

        let candidate = try runCLI(arguments: ["references", "--json", "--path", file.path])
        XCTAssertEqual(candidate.status, 1)

        guard let data = candidate.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = json["findings"] as? [[String: Any]],
              let finding = findings.first(where: { ($0["code"] as? String) == "external_reference_missing" }) else {
            return XCTFail("Missing finding: \(candidate.stdout)")
        }
        XCTAssertTrue((finding["recommendation"] as? String ?? "").contains("Confirm whether this setting is currently in use"))
    }
}

