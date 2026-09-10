import Foundation
import XCTest
@testable import MacBayKit

final class SpaceGuardMigrationTests: XCTestCase {
    private var tempDir: URL!
    private var appsDir: URL!
    private var volumeDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        let unique = UUID().uuidString
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(FileManager.default.temporaryDirectory.path, &buffer)
        let resolvedTemp = String(cString: buffer)
        tempDir = URL(fileURLWithPath: resolvedTemp).appendingPathComponent("MacBaySpaceTests-\(unique)")
        appsDir = tempDir.appendingPathComponent("Applications")
        volumeDir = tempDir.appendingPathComponent("Volumes/ExternalSSD")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeInfo(
        mountPoint: String,
        isInternal: Bool = false,
        totalBytes: UInt64 = 1_000_000_000_000,
        availableBytes: UInt64
    ) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: URL(fileURLWithPath: mountPoint).lastPathComponent,
            totalBytes: totalBytes,
            availableBytes: availableBytes
        )
    }

    private func makeMigrator(
        volumeInfo: VolumeDiskInfo,
        internalInfo: VolumeDiskInfo? = nil
    ) -> BundleMigrator {
        var mapping: [String: VolumeDiskInfo] = [volumeDir.path: volumeInfo]
        if let internalInfo {
            mapping["/"] = internalInfo
        }
        let volumeManager = VolumeManager(
            diskInfoProvider: MockDiskInfoProvider(mapping),
            volumeMountPrefix: tempDir.appendingPathComponent("Volumes").path
        )
        return BundleMigrator(
            fileManager: .default,
            commandRunner: TestBundleCommandRunner(entitlementsXml: "<plist><dict></dict></plist>"),
            volumeManager: volumeManager
        )
    }

    private func createAppBundle(at url: URL, executableName: String) throws {
        let macosDir = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try Data("binary payload".utf8).write(to: macosDir.appendingPathComponent(executableName))

        let plistDict: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.\(executableName)",
            "CFBundleName": executableName,
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistData.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func createPayloadDirectory(at url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 7, count: byteCount).write(to: url.appendingPathComponent("payload"))
    }

    func testDockDryRunIncludesSpacePreview() throws {
        let appURL = appsDir.appendingPathComponent("Preview.app")
        try createAppBundle(at: appURL, executableName: "Preview")

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 900_000_000_000),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 100_000_000_000)
        )

        let result = try migrator.dock(appName: appURL.path, on: volumeDir, dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.messages.contains { $0.contains("Space: destination free") })
        XCTAssertTrue(result.messages.contains { $0.contains("Space: estimated free after copy") })
        XCTAssertTrue(result.messages.contains { $0.contains("Space: estimated internal space freed") })
        XCTAssertFalse(result.messages.contains { $0.contains("insufficient") })
        XCTAssertTrue(result.messages.contains("Dry run: no files were changed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volumeDir.appendingPathComponent("MacBay").path))
    }

    func testDockDryRunReportsShortfallWithoutFailing() throws {
        let appURL = appsDir.appendingPathComponent("TooBig.app")
        try createAppBundle(at: appURL, executableName: "TooBig")

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 1),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 100_000_000_000)
        )

        let result = try migrator.dock(appName: appURL.path, on: volumeDir, dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.messages.contains { $0.contains("Space: insufficient —") })
        XCTAssertTrue(result.messages.contains { $0.contains("short on \(volumeDir.path)") })
    }

    func testDockRefusesWhenDestinationIsFull() throws {
        let appURL = appsDir.appendingPathComponent("NoRoom.app")
        try createAppBundle(at: appURL, executableName: "NoRoom")

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 1),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 100_000_000_000)
        )

        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeDir, dryRun: false)) { error in
            guard case MacBayError.insufficientSpace = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volumeDir.appendingPathComponent("MacBay").path))
    }

    func testDockRefusesWhenCapacityIsUnknown() throws {
        let appURL = appsDir.appendingPathComponent("Unknown.app")
        try createAppBundle(at: appURL, executableName: "Unknown")

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, totalBytes: 0, availableBytes: 0),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 100_000_000_000)
        )

        XCTAssertThrowsError(try migrator.dock(appName: appURL.path, on: volumeDir, dryRun: false)) { error in
            guard case MacBayError.spaceCheckFailed = error else {
                return XCTFail("Expected spaceCheckFailed, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volumeDir.appendingPathComponent("MacBay").path))
    }

    func testDockOmitsInternalFreedLineWhenSourceVolumeIsUnknown() throws {
        let appURL = appsDir.appendingPathComponent("ExternalSource.app")
        try createAppBundle(at: appURL, executableName: "ExternalSource")

        // No mapping for the source path, so the internal contribution cannot be determined.
        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 900_000_000_000)
        )

        let result = try migrator.dock(appName: appURL.path, on: volumeDir, dryRun: true)

        XCTAssertTrue(result.messages.contains { $0.contains("Space: destination free") })
        XCTAssertFalse(result.messages.contains { $0.contains("internal space freed") })
    }

    func testUndockDryRunIncludesInternalSpacePreview() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Restore.app")
        try createPayloadDirectory(at: externalApp, byteCount: 2048)
        let linkURL = appsDir.appendingPathComponent("Restore.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 900_000_000_000),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 100_000_000_000)
        )

        let result = try migrator.undock(appName: linkURL.path, from: volumeDir, dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.messages.contains { $0.contains("Space: destination free") && $0.contains("on /") })
        XCTAssertTrue(result.messages.contains("Dry run: no files were changed"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), externalApp.path)
    }

    func testUndockRefusesWhenInternalSpaceIsInsufficient() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/NoRoom.app")
        try createPayloadDirectory(at: externalApp, byteCount: 65536)
        let linkURL = appsDir.appendingPathComponent("NoRoom.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 900_000_000_000),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, availableBytes: 1)
        )

        XCTAssertThrowsError(try migrator.undock(appName: linkURL.path, from: volumeDir, dryRun: false)) { error in
            guard case MacBayError.insufficientSpace = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalApp.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), externalApp.path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: appsDir.path)
        XCTAssertEqual(leftovers, ["NoRoom.app"])
    }

    func testUndockRefusesWhenInternalCapacityIsUnknown() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Mystery.app")
        try createPayloadDirectory(at: externalApp, byteCount: 1024)
        let linkURL = appsDir.appendingPathComponent("Mystery.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let migrator = makeMigrator(
            volumeInfo: makeInfo(mountPoint: volumeDir.path, availableBytes: 900_000_000_000),
            internalInfo: makeInfo(mountPoint: "/", isInternal: true, totalBytes: 0, availableBytes: 0)
        )

        XCTAssertThrowsError(try migrator.undock(appName: linkURL.path, from: volumeDir, dryRun: false)) { error in
            guard case MacBayError.spaceCheckFailed = error else {
                return XCTFail("Expected spaceCheckFailed, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalApp.path))
    }
}
