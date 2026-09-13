import Foundation
import XCTest
@testable import MacBayKit

final class XcodeDoctorTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!
    private var volumeURL: URL!
    private var xcodeSourceDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        homeDir = tempDir.appendingPathComponent("UserHome")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        xcodeSourceDir = homeDir.appendingPathComponent("Library/Developer/Xcode")
        try FileManager.default.createDirectory(at: xcodeSourceDir, withIntermediateDirectories: true)
        volumeURL = tempDir.appendingPathComponent("ExtDrive")
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLegacySymlinkIsPreservedAndReported() throws {
        // Legacy target on the same external volume
        let legacyTarget = volumeURL.appendingPathComponent("Developer/Xcode/iOS DeviceSupport")
        try FileManager.default.createDirectory(at: legacyTarget, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: legacyTarget.appendingPathComponent("device.data"))

        let linkSource = xcodeSourceDir.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: legacyTarget)

        let mockDisk = MockDiskInfoProvider([
            legacyTarget.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.eligibleExternalVolumePlist.replacingOccurrences(of: "/Volumes/ExternalSSD", with: volumeURL.path),
                fallbackPath: volumeURL.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        let report = try doctor.run(on: volumeURL, dryRun: true)
        let deviceSupport = try XCTUnwrap(report.deviceSupport)

        XCTAssertEqual(deviceSupport.sourcePath, linkSource.path)
        XCTAssertEqual(deviceSupport.destinationPath, legacyTarget.path)
        XCTAssertEqual(deviceSupport.sizeBytes, 64)
        XCTAssertTrue(deviceSupport.messages.contains { $0.contains("legacy external path") })
    }

    func testBrokenSymlinkThrowsPathMissing() throws {
        let nonExistentTarget = volumeURL.appendingPathComponent("Developer/Xcode/DeletedTarget")
        let linkSource = xcodeSourceDir.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: nonExistentTarget)

        let mockDisk = MockDiskInfoProvider([:])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        XCTAssertThrowsError(try doctor.run(on: volumeURL, dryRun: true)) { error in
            guard case MacBayError.pathMissing = error else {
                return XCTFail("Expected pathMissing, got \(error)")
            }
        }
    }

    func testInternalDiskLinkThrowsInvalidVolume() throws {
        let internalTarget = homeDir.appendingPathComponent("InternalStorage/iOS DeviceSupport")
        try FileManager.default.createDirectory(at: internalTarget, withIntermediateDirectories: true)

        let linkSource = xcodeSourceDir.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: internalTarget)

        let mockDisk = MockDiskInfoProvider([
            internalTarget.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.internalVolumePlist,
                fallbackPath: "/"
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        XCTAssertThrowsError(try doctor.run(on: volumeURL, dryRun: true)) { error in
            guard case MacBayError.invalidVolume = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
        }
    }

    func testDifferentVolumeLinkThrowsInvalidVolume() throws {
        let otherVolume = tempDir.appendingPathComponent("OtherDrive")
        try FileManager.default.createDirectory(at: otherVolume, withIntermediateDirectories: true)
        let otherTarget = otherVolume.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createDirectory(at: otherTarget, withIntermediateDirectories: true)

        let linkSource = xcodeSourceDir.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: otherTarget)

        let mockDisk = MockDiskInfoProvider([
            otherTarget.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.eligibleExternalVolumePlist.replacingOccurrences(of: "/Volumes/ExternalSSD", with: otherVolume.path),
                fallbackPath: otherVolume.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        XCTAssertThrowsError(try doctor.run(on: volumeURL, dryRun: true)) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
            XCTAssertTrue(message.contains("different volume"))
        }
    }

    func testIneligibleExternalVolumeThrowsInvalidVolume() throws {
        let nonApfsTarget = volumeURL.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createDirectory(at: nonApfsTarget, withIntermediateDirectories: true)

        let linkSource = xcodeSourceDir.appendingPathComponent("iOS DeviceSupport")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: nonApfsTarget)

        let mockDisk = MockDiskInfoProvider([
            nonApfsTarget.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.nonApfsPlist.replacingOccurrences(of: "/Volumes/ExFAT", with: volumeURL.path),
                fallbackPath: volumeURL.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        XCTAssertThrowsError(try doctor.run(on: volumeURL, dryRun: true)) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
            XCTAssertTrue(message.contains("not eligible"))
        }
    }

    func testArchivesLegacySymlinkIsPreservedAndReported() throws {
        let legacyTarget = volumeURL.appendingPathComponent("Developer/Xcode/Archives")
        try FileManager.default.createDirectory(at: legacyTarget, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 128).write(to: legacyTarget.appendingPathComponent("archive.xcarchive"))

        let linkSource = xcodeSourceDir.appendingPathComponent("Archives")
        try FileManager.default.createSymbolicLink(at: linkSource, withDestinationURL: legacyTarget)

        let mockDisk = MockDiskInfoProvider([
            legacyTarget.path: try SystemDiskInfoProvider.parsePlist(
                VolumeManagerTests.eligibleExternalVolumePlist.replacingOccurrences(of: "/Volumes/ExternalSSD", with: volumeURL.path),
                fallbackPath: volumeURL.path
            )
        ])
        let volumeManager = VolumeManager(
            diskInfoProvider: mockDisk,
            volumeMountPrefix: tempDir.path
        )
        let doctor = XcodeDoctor(
            volumeManager: volumeManager,
            homeDirectory: homeDir
        )

        let options = XcodeDoctorOptions(externalizeDeviceSupport: false, externalizeArchives: true)
        let report = try doctor.run(on: volumeURL, options: options, dryRun: true)
        let archives = try XCTUnwrap(report.archives)

        XCTAssertEqual(archives.sourcePath, linkSource.path)
        XCTAssertEqual(archives.destinationPath, legacyTarget.path)
        XCTAssertEqual(archives.sizeBytes, 128)
        XCTAssertTrue(archives.messages.contains { $0.contains("legacy external path") })
    }

    func testCleanDerivedDataRemovesFilesAndReportsFreedBytes() throws {
        let derivedDataDir = xcodeSourceDir.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: derivedDataDir, withIntermediateDirectories: true)
        let projectBuildDir = derivedDataDir.appendingPathComponent("MyProject-abcdef")
        try FileManager.default.createDirectory(at: projectBuildDir, withIntermediateDirectories: true)
        try Data(repeating: 0x99, count: 256).write(to: projectBuildDir.appendingPathComponent("build.data"))

        let doctor = XcodeDoctor(homeDirectory: homeDir)

        // 1. Dry run
        let dryOptions = XcodeDoctorOptions(
            externalizeDeviceSupport: false,
            externalizeArchives: false,
            cleanDerivedData: true
        )
        let dryReport = try doctor.run(on: volumeURL, options: dryOptions, dryRun: true)
        let dryCleanup = try XCTUnwrap(dryReport.derivedDataCleanup)
        XCTAssertTrue(dryCleanup.succeeded)
        XCTAssertTrue(dryCleanup.output.contains("Dry run: would clean"))
        XCTAssertEqual(dryReport.freedBytes, 256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectBuildDir.path))

        // 2. Real run
        let realReport = try doctor.run(on: volumeURL, options: dryOptions, dryRun: false)
        let realCleanup = try XCTUnwrap(realReport.derivedDataCleanup)
        XCTAssertTrue(realCleanup.succeeded)
        XCTAssertTrue(realCleanup.output.contains("Cleaned"))
        XCTAssertEqual(realReport.freedBytes, 256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectBuildDir.path))
    }

    func testCleanCachesRemovesSimulatorAndXcodeCaches() throws {
        let simCacheDir = homeDir.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        let xcodeCacheDir = homeDir.appendingPathComponent("Library/Caches/com.apple.dt.Xcode")
        try FileManager.default.createDirectory(at: simCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcodeCacheDir, withIntermediateDirectories: true)

        try Data(repeating: 0x11, count: 50).write(to: simCacheDir.appendingPathComponent("sim.cache"))
        try Data(repeating: 0x22, count: 70).write(to: xcodeCacheDir.appendingPathComponent("xcode.cache"))

        let doctor = XcodeDoctor(homeDirectory: homeDir)

        let options = XcodeDoctorOptions(
            externalizeDeviceSupport: false,
            externalizeArchives: false,
            cleanCaches: true
        )
        let report = try doctor.run(on: volumeURL, options: options, dryRun: false)
        let cleanup = try XCTUnwrap(report.cacheCleanup)
        XCTAssertTrue(cleanup.succeeded)
        XCTAssertEqual(report.freedBytes, 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: simCacheDir.appendingPathComponent("sim.cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xcodeCacheDir.appendingPathComponent("xcode.cache").path))
    }

    func testXcodeRunningThrowsUnsupportedOperationUnlessForce() throws {
        let runner = MockXcodeCommandRunner()
        runner.pgrepStatus = 0 // Xcode is running!

        let doctor = XcodeDoctor(
            commandRunner: runner,
            homeDirectory: homeDir
        )

        let normalOptions = XcodeDoctorOptions(cleanDerivedData: true, force: false)
        XCTAssertThrowsError(try doctor.run(on: volumeURL, options: normalOptions, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(msg) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(msg.contains("Xcode is currently running"))
        }

        let forceOptions = XcodeDoctorOptions(cleanDerivedData: true, force: true)
        XCTAssertNoThrow(try doctor.run(on: volumeURL, options: forceOptions, dryRun: true))
    }
}

private final class MockXcodeCommandRunner: CommandRunner, @unchecked Sendable {
    var pgrepStatus: Int32 = 1

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        if executable.contains("pgrep") {
            return CommandResult(status: pgrepStatus, standardOutput: "", standardError: "")
        }
        if executable.contains("xcrun") {
            return CommandResult(status: 0, standardOutput: "Deleted 0 simulators", standardError: "")
        }
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}
