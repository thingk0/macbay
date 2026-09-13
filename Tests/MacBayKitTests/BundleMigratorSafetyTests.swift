import Foundation
import XCTest
@testable import MacBayKit

final class BundleMigratorSafetyTests: XCTestCase {
    private var tempDir: URL!
    private var appsDir: URL!
    private var volumeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        appsDir = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        volumeURL = URL(fileURLWithPath: "/Volumes/ExternalSSD")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBlockedAppIsNeverMigrated() throws {
        let appURL = appsDir.appendingPathComponent("Blocked.app")
        try createAppBundle(at: appURL, executableName: "Blocked")

        let entitlementsXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
        """
        let runner = TestBundleCommandRunner(entitlementsXml: entitlementsXml)
        let mockDisk = MockDiskInfoProvider([
            "/Volumes/ExternalSSD": try SystemDiskInfoProvider.parsePlist(VolumeManagerTests.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")
        ])
        let volumeManager = VolumeManager(diskInfoProvider: mockDisk)
        let inspector = AppInspector(commandRunner: runner)

        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager,
            appInspector: inspector
        )

        // Blocked fails even with force=true
        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeURL, dryRun: false, force: true)) { error in
            guard case let MacBayError.compatibilityBlocked(path, assessment) = error else {
                return XCTFail("Expected compatibilityBlocked, got \(error)")
            }
            XCTAssertEqual(assessment.grade, .blocked)
            XCTAssertEqual(path, appURL.path)
        }

        // Blocked fails even on dryRun
        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeURL, dryRun: true, force: false)) { error in
            guard case let MacBayError.compatibilityBlocked(_, assessment) = error else {
                return XCTFail("Expected compatibilityBlocked on dryRun, got \(error)")
            }
            XCTAssertEqual(assessment.grade, .blocked)
        }
    }

    func testPopupRiskRequiresForceForRealMigration() throws {
        let appURL = appsDir.appendingPathComponent("PopupRisk.app")
        try createAppBundle(at: appURL, executableName: "PopupRisk")
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        try FileManager.default.createDirectory(at: asarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("moveToApplicationsFolder".utf8).write(to: asarURL)

        let runner = TestBundleCommandRunner(entitlementsXml: "<plist><dict></dict></plist>")
        let mockDisk = MockDiskInfoProvider([
            "/Volumes/ExternalSSD": try SystemDiskInfoProvider.parsePlist(VolumeManagerTests.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")
        ])
        let volumeManager = VolumeManager(diskInfoProvider: mockDisk)
        let inspector = AppInspector(commandRunner: runner)

        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager,
            appInspector: inspector
        )

        // dry-run succeeds without force and returns warnings
        let dryResult = try migrator.dock(appName: appURL.path, on: volumeURL, dryRun: true, force: false)
        XCTAssertTrue(dryResult.dryRun)
        XCTAssertEqual(dryResult.compatibility?.grade, .popupRisk)
        XCTAssertTrue(dryResult.messages.contains { $0.contains("Warning: Application is flagged with popup risks") })

        // Real migration without force throws forceRequired
        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeURL, dryRun: false, force: false)) { error in
            guard case let MacBayError.forceRequired(path, assessment) = error else {
                return XCTFail("Expected forceRequired, got \(error)")
            }
            XCTAssertEqual(path, appURL.path)
            XCTAssertEqual(assessment.grade, .popupRisk)
        }
    }

    func testCodeSignatureFailureStopsMigration() throws {
        let appURL = appsDir.appendingPathComponent("Unsigned.app")
        try createAppBundle(at: appURL, executableName: "Unsigned")

        let runner = TestBundleCommandRunner(
            entitlementsXml: "<plist><dict></dict></plist>",
            verifyStatus: 1,
            verifyStderr: "code object is not signed at all"
        )
        let mockDisk = MockDiskInfoProvider([
            "/Volumes/ExternalSSD": try SystemDiskInfoProvider.parsePlist(VolumeManagerTests.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")
        ])
        let volumeManager = VolumeManager(diskInfoProvider: mockDisk)

        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager
        )

        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeURL, dryRun: false)) { error in
            guard case MacBayError.signatureVerificationFailed = error else {
                return XCTFail("Expected signatureVerificationFailed, got \(error)")
            }
        }
    }

    func testDestinationExistsError() throws {
        let appURL = appsDir.appendingPathComponent("Colliding.app")
        try createAppBundle(at: appURL, executableName: "Colliding")

        let tempVolume = tempDir.appendingPathComponent("ExternalSSD")
        let existingDest = tempVolume.appendingPathComponent("MacBay/Applications/Colliding.app")
        try FileManager.default.createDirectory(at: existingDest, withIntermediateDirectories: true)

        let runner = TestBundleCommandRunner(entitlementsXml: "<plist><dict></dict></plist>")
        let mockDisk = MockDiskInfoProvider([
            tempVolume.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.eligibleExternalVolumePlist.replacingOccurrences(of: "/Volumes/ExternalSSD", with: tempVolume.path),
                fallbackPath: tempVolume.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )

        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager
        )

        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: tempVolume, dryRun: true)) { error in
            guard case MacBayError.destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }
    }

    func testCopyRollbackOnVerificationFailure() throws {
        let appURL = appsDir.appendingPathComponent("Rollback.app")
        try createAppBundle(at: appURL, executableName: "Rollback")

        let tempVolume = tempDir.appendingPathComponent("ExtVolume")
        try FileManager.default.createDirectory(at: tempVolume, withIntermediateDirectories: true)

        let runner = TestBundleCommandRunner(
            entitlementsXml: "<plist><dict></dict></plist>",
            failOnSecondVerify: true
        )
        let mockDisk = MockDiskInfoProvider([
            tempVolume.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.eligibleExternalVolumePlist.replacingOccurrences(of: "/Volumes/ExternalSSD", with: tempVolume.path),
                fallbackPath: tempVolume.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )

        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager
        )

        let expectedDestination = tempVolume.appendingPathComponent("MacBay/Applications/Rollback.app")
        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: tempVolume, dryRun: false)) { error in
            guard case MacBayError.signatureVerificationFailed = error else {
                return XCTFail("Expected signatureVerificationFailed, got \(error)")
            }
        }

        // Destination must be cleaned up on rollback
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedDestination.path))
        // Source must remain untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    private func createAppBundle(at url: URL, executableName: String) throws {
        let macosDir = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let execURL = macosDir.appendingPathComponent(executableName)
        try Data("binary payload".utf8).write(to: execURL)

        let plistDict: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.\(executableName)",
            "CFBundleName": executableName,
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistData.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}

final class TestBundleCommandRunner: CommandRunner, @unchecked Sendable {
    let entitlementsXml: String
    var verifyStatus: Int32
    var verifyStderr: String
    var failOnSecondVerify: Bool
    private var verifyCount = 0

    init(
        entitlementsXml: String,
        verifyStatus: Int32 = 0,
        verifyStderr: String = "",
        failOnSecondVerify: Bool = false
    ) {
        self.entitlementsXml = entitlementsXml
        self.verifyStatus = verifyStatus
        self.verifyStderr = verifyStderr
        self.failOnSecondVerify = failOnSecondVerify
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        if arguments.contains("--entitlements") {
            return CommandResult(status: 0, standardOutput: entitlementsXml, standardError: "")
        }
        if arguments.contains("--verify") {
            verifyCount += 1
            if failOnSecondVerify && verifyCount > 1 {
                return CommandResult(status: 1, standardOutput: "", standardError: "Destination verification failed")
            }
            return CommandResult(status: verifyStatus, standardOutput: "", standardError: verifyStderr)
        }
        if executable.contains("ditto") {
            // Simulate ditto copying: dst becomes a copy of src (parent must exist)
            if arguments.count >= 5 {
                let src = arguments[arguments.count - 2]
                let dst = arguments[arguments.count - 1]
                let fileManager = FileManager.default
                try? fileManager.createDirectory(
                    atPath: (dst as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try? fileManager.removeItem(atPath: dst)
                try? fileManager.copyItem(atPath: src, toPath: dst)
            }
            return CommandResult(status: 0, standardOutput: "", standardError: "")
        }
        if arguments.contains("-nP") {
            // lsof: no locks
            return CommandResult(status: 1, standardOutput: "", standardError: "")
        }
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}
