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
}
