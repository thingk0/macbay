import Foundation
import XCTest
@testable import MacBayKit

final class LocalAppRecoveryTests: XCTestCase {
    private var fixture: RecoveryFixture!

    override func setUpWithError() throws {
        fixture = try RecoveryFixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testDryRunPreservesLinkCandidateAndManifest() throws {
        let report = try fixture.recover(dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testRecoveryInstallsVerifiedLocalAppAndKeepsSourceBundle() throws {
        let report = try fixture.recover(dryRun: false)

        XCTAssertFalse(report.dryRun)
        XCTAssertFalse(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalApp.path))
        XCTAssertTrue(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.isEmpty)
        XCTAssertEqual(try fixture.bundleIdentifier(at: fixture.localApp), "com.anysphere.sand")
    }

    func testBundleIdentifierMismatchLeavesLinkAndManifestUntouched() throws {
        XCTAssertThrowsError(try fixture.recover(
            expectedBundleIdentifier: "com.example.wrong",
            dryRun: false
        ))
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testTeamIdentifierMismatchLeavesLinkAndManifestUntouched() throws {
        XCTAssertThrowsError(try fixture.recover(
            expectedTeamIdentifier: "WRONGTEAM",
            dryRun: false
        ))
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testInvalidSignatureLeavesLinkAndManifestUntouched() throws {
        fixture.runner.signatureStatus = 1
        XCTAssertThrowsError(try fixture.recover(dryRun: false)) { error in
            guard case MacBayError.signatureVerificationFailed = error else {
                return XCTFail("Expected signatureVerificationFailed, got \(error)")
            }
        }
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testChangedBrokenLinkTargetStopsRecovery() throws {
        try FileManager.default.removeItem(at: fixture.localApp)
        let unexpected = fixture.volume.appendingPathComponent("MacBay/Applications/Other.app")
        try FileManager.default.createSymbolicLink(at: fixture.localApp, withDestinationURL: unexpected)

        XCTAssertThrowsError(try fixture.recover(dryRun: false))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.localApp.path), unexpected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testMissingMatchingManifestRecordStopsRecovery() throws {
        try ManifestStore(fileManager: fixture.fileManager).updating(on: fixture.volume) { manifest in
            manifest.items.removeAll()
        }

        XCTAssertThrowsError(try fixture.recover(dryRun: false)) { error in
            guard case MacBayError.manifestFailed = error else {
                return XCTFail("Expected manifestFailed, got \(error)")
            }
        }
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
    }

    func testRunningRecoveryCandidateIsNotCopied() throws {
        fixture.runner.lockedPath = fixture.candidate.path

        XCTAssertThrowsError(try fixture.recover(dryRun: false)) { error in
            guard case MacBayError.activeProcesses = error else {
                return XCTFail("Expected activeProcesses, got \(error)")
            }
        }
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
    }

    func testCopyFailurePreservesCandidateAndBrokenLink() throws {
        fixture.runner.copyStatus = 9

        XCTAssertThrowsError(try fixture.recover(dryRun: false))

        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.apps.path)
        XCTAssertFalse(leftovers.contains { $0.contains("macbay-recover") })
        XCTAssertEqual(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.count, 1)
    }

    func testDetachedVolumePreservesCandidateAndBrokenLink() throws {
        fixture.fileManager.mountedPaths = ["/"]
        XCTAssertThrowsError(try fixture.recover(dryRun: false))
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
    }

    func testInsufficientInternalSpacePreservesCandidateAndBrokenLink() throws {
        fixture.diskInfo.mapping["/"] = fixture.diskInfo.makeDiskInfo(
            path: "/",
            internal: true,
            availableBytes: 0
        )
        XCTAssertThrowsError(try fixture.recover(dryRun: false)) { error in
            guard case MacBayError.insufficientSpace = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
        }
        XCTAssertTrue(fixture.isLink(fixture.localApp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.candidate.path))
    }

    func testPreviouslyInstalledVerifiedCopyCanFinishManifestCleanup() throws {
        try FileManager.default.removeItem(at: fixture.localApp)
        try FileManager.default.copyItem(at: fixture.candidate, to: fixture.localApp)

        _ = try fixture.recover(dryRun: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localApp.path))
        XCTAssertFalse(fixture.isLink(fixture.localApp))
        XCTAssertTrue(try ManifestStore(fileManager: fixture.fileManager).load(on: fixture.volume).items.isEmpty)
    }
}

private final class RecoveryTestFileManager: FileManager, @unchecked Sendable {
    var mountedPaths: [String]

    init(mountedPaths: [String]) {
        self.mountedPaths = mountedPaths
        super.init()
    }

    override func mountedVolumeURLs(
        includingResourceValuesForKeys propertyKeys: [URLResourceKey]?,
        options: FileManager.VolumeEnumerationOptions = []
    ) -> [URL]? {
        mountedPaths.map { URL(fileURLWithPath: $0) }
    }
}

private final class RecoveryDiskInfoProvider: DiskInfoProvider, @unchecked Sendable {
    var mapping: [String: VolumeDiskInfo]

    init(mapping: [String: VolumeDiskInfo]) {
        self.mapping = mapping
    }

    func diskInfo(for path: String) throws -> VolumeDiskInfo {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let exact = mapping[path] ?? mapping[standardized] { return exact }
        for (key, info) in mapping.sorted(by: { $0.key.count > $1.key.count }) {
            let normalized = URL(fileURLWithPath: key).standardizedFileURL.path
            if standardized.hasPrefix(normalized + "/") { return info }
        }
        throw MacBayError.invalidVolume("No fixture disk metadata for \(path)")
    }

    func makeDiskInfo(path: String, internal isInternal: Bool, availableBytes: UInt64) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: path,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: URL(fileURLWithPath: path).lastPathComponent,
            totalBytes: 100_000_000_000,
            availableBytes: availableBytes,
            volumeUUID: path == "/" ? "INTERNAL" : "RECOVERY-TEST"
        )
    }
}

private final class RecoveryTestCommandRunner: CommandRunner, @unchecked Sendable {
    var signatureStatus: Int32 = 0
    var copyStatus: Int32 = 0
    var teamIdentifier = "TESTTEAM"
    var lockedPath: String?

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        if executable == "/usr/sbin/lsof" {
            guard let lockedPath else { return CommandResult(status: 1) }
            return CommandResult(
                status: 0,
                standardOutput: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nGrok 123 tester 1r REG 1,2 100 42 \(lockedPath)\n"
            )
        }
        if executable == "/usr/bin/codesign", arguments.contains("--verify") {
            return CommandResult(status: signatureStatus, standardError: "signature rejected")
        }
        if executable == "/usr/bin/codesign", arguments.first == "-dv" {
            return CommandResult(status: 0, standardError: "TeamIdentifier=\(teamIdentifier)\n")
        }
        if executable == "/usr/bin/ditto" {
            guard copyStatus == 0 else {
                return CommandResult(status: copyStatus, standardError: "copy failed")
            }
            let source = arguments[0]
            let destination = arguments[1]
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        }
        return CommandResult(status: 0)
    }
}

private final class RecoveryFixture {
    let root: URL
    let volume: URL
    let volumePrefix: URL
    let apps: URL
    let localApp: URL
    let externalApp: URL
    let candidate: URL
    let fileManager: RecoveryTestFileManager
    let diskInfo: RecoveryDiskInfoProvider
    let runner: RecoveryTestCommandRunner
    let manager: LocalAppRecoveryManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        volumePrefix = root.appendingPathComponent("Volumes", isDirectory: true)
        volume = volumePrefix.appendingPathComponent("KLEVV", isDirectory: true)
        apps = root.appendingPathComponent("Applications", isDirectory: true)
        localApp = apps.appendingPathComponent("Grok Bot.app", isDirectory: true)
        externalApp = MacBayPaths.applicationsRoot(on: volume).appendingPathComponent("Grok Bot.app", isDirectory: true)
        candidate = root.appendingPathComponent("staged/Grok Bot.app", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MacBayPaths.applicationsRoot(on: volume), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidate.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 512).write(to: candidate.appendingPathComponent("Contents/MacOS/Grok Bot"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.anysphere.sand",
            "CFBundleShortVersionString": "0.58.0",
            "CFBundleVersion": "58",
            "CFBundleExecutable": "Grok Bot",
            "CFBundlePackageType": "APPL"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: candidate.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: localApp.path, withDestinationPath: externalApp.path)

        let mountedInfo = Self.diskInfo(path: volume.path, isInternal: false, availableBytes: 20_000_000_000)
        let internalInfo = Self.diskInfo(path: "/", isInternal: true, availableBytes: 500_000_000_000)
        fileManager = RecoveryTestFileManager(mountedPaths: ["/", volume.path])
        diskInfo = RecoveryDiskInfoProvider(mapping: [volume.path: mountedInfo, "/": internalInfo])
        runner = RecoveryTestCommandRunner()
        let volumeManager = VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: diskInfo,
            volumeMountPrefix: volumePrefix.path
        )
        manager = LocalAppRecoveryManager(
            fileManager: fileManager,
            commandRunner: runner,
            volumeManager: volumeManager,
            operationLock: NoOpVolumeOperationLock(),
            volumeMountPrefix: volumePrefix.path,
            applicationsDirectory: apps
        )
        try ManifestStore(fileManager: fileManager).updating(on: volume) { manifest in
            manifest.items = [DockedItem(
                name: "Grok Bot.app",
                sourcePath: localApp.path,
                externalPath: externalApp.path,
                sizeBytes: 512,
                kind: .application,
                dockedAt: macBayTimestamp()
            )]
        }
    }

    func recover(
        expectedBundleIdentifier: String = "com.anysphere.sand",
        expectedTeamIdentifier: String = "TESTTEAM",
        dryRun: Bool
    ) throws -> LocalAppRecoveryReport {
        try manager.recover(
            appName: "Grok Bot.app",
            from: candidate.path,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            dryRun: dryRun
        )
    }

    func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func bundleIdentifier(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        return info?["CFBundleIdentifier"] as? String
    }

    private static func diskInfo(path: String, isInternal: Bool, availableBytes: UInt64) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: path,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: URL(fileURLWithPath: path).lastPathComponent,
            totalBytes: 100_000_000_000,
            availableBytes: availableBytes,
            volumeUUID: path == "/" ? "INTERNAL" : "RECOVERY-TEST"
        )
    }
}
