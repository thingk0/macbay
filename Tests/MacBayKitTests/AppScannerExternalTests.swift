import Foundation
import XCTest
@testable import MacBayKit

final class AppScannerExternalTests: XCTestCase {
    private var tempDir: URL!
    private var appsDir: URL!
    private var externalVolumeDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        let unique = UUID().uuidString
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(FileManager.default.temporaryDirectory.path, &buffer)
        let resolvedTemp = String(cString: buffer)
        tempDir = URL(fileURLWithPath: resolvedTemp).appendingPathComponent("MacBayScanTests-\(unique)")
        appsDir = tempDir.appendingPathComponent("Applications")
        externalVolumeDir = tempDir.appendingPathComponent("Volumes/ExternalSSD")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalVolumeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeDiskInfo(
        mountPoint: String,
        isInternal: Bool = false,
        filesystemType: String = "apfs",
        isWritableVolume: Bool = true,
        busProtocol: String = "PCI-Express"
    ) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: filesystemType,
            isWritableVolume: isWritableVolume,
            busProtocol: busProtocol,
            volumeName: URL(fileURLWithPath: mountPoint).lastPathComponent,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000
        )
    }

    func testManagedExternalAppDetection() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("MacBay/Applications/Managed.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: externalApp.appendingPathComponent("payload"))

        let symlinkApp = appsDir.appendingPathComponent("Managed.app")
        try FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: externalApp)

        let store = ManifestStore()
        let item = DockedItem(
            name: "Managed.app",
            sourcePath: symlinkApp.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path,
            sizeBytes: 1024,
            kind: .application,
            dockedAt: "2026-09-10T12:00:00Z"
        )
        try store.save(DockManifest(items: [item]), on: externalVolumeDir)

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])

        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertEqual(report.externalApplications.count, 1)
        let ext: ExternalApplication = try XCTUnwrap(report.externalApplications.first)
        XCTAssertEqual(ext.name, "Managed.app")
        XCTAssertEqual(URL(fileURLWithPath: ext.sourcePath).standardizedFileURL.path, symlinkApp.standardizedFileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: ext.destinationPath).standardizedFileURL.path, externalApp.standardizedFileURL.path)
        XCTAssertEqual(ext.managementStatus, .macBay)
        XCTAssertEqual(ext.managementStatus.badge, "[MacBay]")
        XCTAssertNotNil(ext.sizeBytes)
        XCTAssertTrue(report.unresolvedApplicationLinks.isEmpty)
    }

    func testUnmanagedExternalAppDetection() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("Custom/Unmanaged.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 512).write(to: externalApp.appendingPathComponent("payload"))

        let symlinkApp = appsDir.appendingPathComponent("Unmanaged.app")
        try FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: externalApp)

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])

        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertEqual(report.externalApplications.count, 1)
        let ext: ExternalApplication = try XCTUnwrap(report.externalApplications.first)
        XCTAssertEqual(ext.name, "Unmanaged.app")
        XCTAssertEqual(URL(fileURLWithPath: ext.sourcePath).standardizedFileURL.path, symlinkApp.standardizedFileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: ext.destinationPath).standardizedFileURL.path, externalApp.standardizedFileURL.path)
        XCTAssertEqual(ext.managementStatus, .unmanaged)
        XCTAssertEqual(ext.managementStatus.badge, "[Unmanaged]")
    }

    func testUnconfirmedExternalAppDetectionWhenManifestCorrupted() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("MacBay/Applications/BrokenManifest.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data("corrupted data".utf8).write(to: externalApp.appendingPathComponent("payload"))

        let symlinkApp = appsDir.appendingPathComponent("BrokenManifest.app")
        try FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: externalApp)

        let manifestFile = MacBayPaths.manifestURL(on: externalVolumeDir)
        try FileManager.default.createDirectory(at: manifestFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("INVALID_JSON{[[[".utf8).write(to: manifestFile)

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])

        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertEqual(report.externalApplications.count, 1)
        let ext: ExternalApplication = try XCTUnwrap(report.externalApplications.first)
        XCTAssertEqual(ext.name, "BrokenManifest.app")
        XCTAssertEqual(ext.managementStatus, .unconfirmed)
        XCTAssertEqual(ext.managementStatus.badge, "[Unconfirmed]")
    }

    func testRelativeAndChainedSymlinkResolution() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("Applications/Target.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: externalApp.appendingPathComponent("file"))

        // Create intermediate symlink LinkB -> Target.app
        let intermediate = appsDir.appendingPathComponent("LinkB.app")
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: externalApp)

        // Create relative symlink LinkA -> LinkB.app
        let firstLink = appsDir.appendingPathComponent("LinkA.app")
        try FileManager.default.createSymbolicLink(atPath: firstLink.path, withDestinationPath: "LinkB.app")

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])

        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        let extNames = report.externalApplications.map(\.name)
        XCTAssertTrue(extNames.contains("LinkA.app"))
        XCTAssertTrue(extNames.contains("LinkB.app"))
    }

    func testCircularSymlinkDetection() throws {
        let loopA = appsDir.appendingPathComponent("LoopA.app")
        let loopB = appsDir.appendingPathComponent("LoopB.app")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.path)
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.path)

        let mockDisk = MockDiskInfoProvider([:])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertTrue(report.externalApplications.isEmpty)
        XCTAssertEqual(report.unresolvedApplicationLinks.count, 2)
        for link in report.unresolvedApplicationLinks {
            XCTAssertEqual(link.reason, "Circular link detected")
        }
    }

    func testBrokenSymlinkTargetUnavailable() throws {
        let broken = appsDir.appendingPathComponent("Offline.app")
        let missingTarget = externalVolumeDir.appendingPathComponent("Applications/Offline.app")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missingTarget)

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertTrue(report.externalApplications.isEmpty)
        XCTAssertEqual(report.unresolvedApplicationLinks.count, 1)
        let link: UnresolvedApplicationLink = try XCTUnwrap(report.unresolvedApplicationLinks.first)
        XCTAssertEqual(link.name, "Offline.app")
        XCTAssertEqual(URL(fileURLWithPath: link.sourcePath).standardizedFileURL.path, broken.standardizedFileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: link.destinationPath).standardizedFileURL.path, missingTarget.standardizedFileURL.path)
        XCTAssertEqual(link.reason, "Target unavailable")
    }

    func testVolumeCheckFailureReportsUnresolvedLink() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("Applications/FaultyVol.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: externalApp.appendingPathComponent("test"))

        let link = appsDir.appendingPathComponent("FaultyVol.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        // Empty mock mapping causes diskInfo(for:) to throw invalidVolume
        let mockDisk = MockDiskInfoProvider([:])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertTrue(report.externalApplications.isEmpty)
        XCTAssertEqual(report.unresolvedApplicationLinks.count, 1)
        let unresolved: UnresolvedApplicationLink = try XCTUnwrap(report.unresolvedApplicationLinks.first)
        XCTAssertEqual(unresolved.name, "FaultyVol.app")
        XCTAssertEqual(unresolved.reason, "Volume check failed")
    }

    func testInternalDiskAndDiskImageSymlinksAreExcluded() throws {
        let internalDir = tempDir.appendingPathComponent("Internal")
        let dmgDir = tempDir.appendingPathComponent("DiskImageMount")
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dmgDir, withIntermediateDirectories: true)

        let internalApp = internalDir.appendingPathComponent("InternalApp.app")
        let dmgApp = dmgDir.appendingPathComponent("DmgApp.app")
        try FileManager.default.createDirectory(at: internalApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dmgApp, withIntermediateDirectories: true)

        let internalLink = appsDir.appendingPathComponent("InternalApp.app")
        let dmgLink = appsDir.appendingPathComponent("DmgApp.app")
        try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: internalApp)
        try FileManager.default.createSymbolicLink(at: dmgLink, withDestinationURL: dmgApp)

        let mockDisk = MockDiskInfoProvider([
            internalDir.path: makeDiskInfo(mountPoint: internalDir.path, isInternal: true),
            dmgDir.path: makeDiskInfo(mountPoint: dmgDir.path, isInternal: false, busProtocol: "Disk Image")
        ])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertTrue(report.externalApplications.isEmpty)
        XCTAssertTrue(report.unresolvedApplicationLinks.isEmpty)
    }

    func testNonApfsAndReadOnlyExternalVolumeIsIncluded() throws {
        let readOnlyVolume = tempDir.appendingPathComponent("Volumes/ReadOnlyExFat")
        let targetApp = readOnlyVolume.appendingPathComponent("ExFatApp.app")
        try FileManager.default.createDirectory(at: targetApp, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: targetApp.appendingPathComponent("file"))

        let link = appsDir.appendingPathComponent("ExFatApp.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetApp)

        let mockDisk = MockDiskInfoProvider([
            readOnlyVolume.path: makeDiskInfo(
                mountPoint: readOnlyVolume.path,
                isInternal: false,
                filesystemType: "msdos",
                isWritableVolume: false,
                busProtocol: "USB"
            )
        ])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(applicationDirectories: [appsDir], developerCacheTargets: [])

        XCTAssertEqual(report.externalApplications.count, 1)
        XCTAssertEqual(report.externalApplications.first?.name, "ExFatApp.app")
    }

    func testSmallAppUnder200MBIsIncludedInExternalApplications() throws {
        let externalApp = externalVolumeDir.appendingPathComponent("Applications/Tiny.app")
        try FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
        try Data("small payload".utf8).write(to: externalApp.appendingPathComponent("file"))

        let link = appsDir.appendingPathComponent("Tiny.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        let mockDisk = MockDiskInfoProvider([
            externalVolumeDir.path: makeDiskInfo(mountPoint: externalVolumeDir.path)
        ])
        let scanner = AppScanner(diskInfoProvider: mockDisk)
        let report = scanner.scan(
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            applicationDirectories: [appsDir],
            developerCacheTargets: []
        )

        // Candidates is empty because Tiny.app is a symlink and < 200MB
        XCTAssertTrue(report.candidates.isEmpty)
        // External applications includes Tiny.app regardless of 200MB threshold
        XCTAssertEqual(report.externalApplications.count, 1)
        XCTAssertEqual(report.externalApplications.first?.name, "Tiny.app")
    }

    func testOutputFormatterScanSections() {
        let formatter = OutputFormatter(useColor: false)
        let ext1 = ExternalApplication(
            name: "Example.app",
            sourcePath: "/Applications/Example.app",
            destinationPath: "/Volumes/KLEVV/Applications/Example.app",
            sizeBytes: 2_254_857_830, // ~2.1 GB
            managementStatus: .macBay
        )
        let ext2 = ExternalApplication(
            name: "Another.app",
            sourcePath: "/Applications/Another.app",
            destinationPath: "/Volumes/KLEVV/Applications/Another.app",
            sizeBytes: 891_289_600, // ~850.0 MB
            managementStatus: .unmanaged
        )
        let ext3 = ExternalApplication(
            name: "UnknownSize.app",
            sourcePath: "/Applications/UnknownSize.app",
            destinationPath: "/Volumes/KLEVV/Applications/UnknownSize.app",
            sizeBytes: nil,
            managementStatus: .unconfirmed
        )
        let unresolved = UnresolvedApplicationLink(
            name: "Offline.app",
            sourcePath: "/Applications/Offline.app",
            destinationPath: "/Volumes/Backup/Applications/Offline.app",
            reason: "Target unavailable"
        )

        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [],
            externalApplications: [ext1, ext2, ext3],
            unresolvedApplicationLinks: [unresolved],
            warnings: []
        )

        let output = formatter.scan(report)

        // Check Header
        XCTAssertTrue(output.contains("MacBay scan"))
        XCTAssertTrue(output.contains("0 apps · 0 caches · 3 external"))
        XCTAssertTrue(output.contains("App threshold: 200.0 MB"))

        // Check Already external section
        XCTAssertTrue(output.contains("Already external · 3"))
        XCTAssertTrue(output.contains("Example.app"))
        XCTAssertTrue(output.contains("2.1 GB"))
        XCTAssertTrue(output.contains("MacBay"))
        XCTAssertTrue(output.contains("→ /Volumes/KLEVV/Applications/Example.app"))
        XCTAssertTrue(output.contains("Another.app"))
        XCTAssertTrue(output.contains("850.0 MB"))
        XCTAssertTrue(output.contains("Unmanaged"))
        XCTAssertTrue(output.contains("UnknownSize.app"))
        XCTAssertTrue(output.contains("Unknown"))
        XCTAssertTrue(output.contains("Unconfirmed"))

        // Check legends
        XCTAssertTrue(output.contains("MacBay: recorded in volume manifest"))
        XCTAssertTrue(output.contains("Unmanaged: no matching MacBay migration record"))
        XCTAssertTrue(output.contains("Unconfirmed: volume manifest read error"))

        // Check Unresolved links section
        XCTAssertTrue(output.contains("Unresolved links · 1"))
        XCTAssertTrue(output.contains("Offline.app — Target unavailable"))
        XCTAssertTrue(output.contains("→ /Volumes/Backup/Applications/Offline.app"))

        // In non-verbose mode, sourcePath should not appear
        XCTAssertFalse(output.contains("    /Applications/Example.app"))
        XCTAssertFalse(output.contains("    /Applications/Offline.app"))

        // In verbose mode, sourcePath should appear
        let verboseOutput = formatter.scan(report, verbose: true)
        XCTAssertTrue(verboseOutput.contains("    /Applications/Example.app"))
        XCTAssertTrue(verboseOutput.contains("    /Applications/Offline.app"))
    }

    func testScanReportBackwardsCompatibleDecoding() throws {
        // Old JSON without externalApplications and unresolvedApplicationLinks
        let oldJson = """
        {
          "candidates": [],
          "generatedAt": "2026-09-10T00:00:00Z",
          "minimumApplicationSizeBytes": 209715200,
          "warnings": []
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScanReport.self, from: Data(oldJson.utf8))
        XCTAssertTrue(decoded.externalApplications.isEmpty)
        XCTAssertTrue(decoded.unresolvedApplicationLinks.isEmpty)

        // Roundtrip new JSON
        let encoder = JSONEncoder()
        let reEncoded = try encoder.encode(decoded)
        let roundTripped = try decoder.decode(ScanReport.self, from: reEncoded)
        XCTAssertEqual(roundTripped, decoded)
    }
}
