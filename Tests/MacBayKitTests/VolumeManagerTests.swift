import Foundation
import XCTest
@testable import MacBayKit

final class VolumeManagerTests: XCTestCase {
    static let eligibleExternalVolumePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/ExternalSSD</string>
        <key>Internal</key>
        <false/>
        <key>FilesystemType</key>
        <string>apfs</string>
        <key>WritableVolume</key>
        <true/>
        <key>BusProtocol</key>
        <string>PCI-Express</string>
        <key>VolumeName</key>
        <string>ExternalSSD</string>
        <key>TotalSize</key>
        <integer>999995129856</integer>
        <key>APFSContainerFree</key>
        <integer>923864829952</integer>
    </dict>
    </plist>
    """

    static let installerDmgPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/ExampleInstallerDMG</string>
        <key>Internal</key>
        <false/>
        <key>FilesystemType</key>
        <string>apfs</string>
        <key>WritableVolume</key>
        <false/>
        <key>BusProtocol</key>
        <string>Disk Image</string>
        <key>VolumeName</key>
        <string>ExampleInstallerDMG</string>
        <key>TotalSize</key>
        <integer>394579968</integer>
        <key>APFSContainerFree</key>
        <integer>65220608</integer>
    </dict>
    </plist>
    """

    static let internalVolumePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/InternalData</string>
        <key>Internal</key>
        <true/>
        <key>FilesystemType</key>
        <string>apfs</string>
        <key>WritableVolume</key>
        <true/>
        <key>BusProtocol</key>
        <string>Apple Fabric</string>
        <key>VolumeName</key>
        <string>InternalData</string>
        <key>TotalSize</key>
        <integer>245107195904</integer>
        <key>APFSContainerFree</key>
        <integer>142427459584</integer>
    </dict>
    </plist>
    """

    static let nonApfsPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/ExFATDrive</string>
        <key>Internal</key>
        <false/>
        <key>FilesystemType</key>
        <string>exfat</string>
        <key>WritableVolume</key>
        <true/>
        <key>BusProtocol</key>
        <string>USB</string>
        <key>VolumeName</key>
        <string>ExFATDrive</string>
        <key>TotalSize</key>
        <integer>500000000000</integer>
        <key>FreeSpace</key>
        <integer>200000000000</integer>
    </dict>
    </plist>
    """

    static let readOnlyPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/ReadOnlyAPFS</string>
        <key>Internal</key>
        <false/>
        <key>FilesystemType</key>
        <string>apfs</string>
        <key>WritableVolume</key>
        <false/>
        <key>BusProtocol</key>
        <string>USB</string>
        <key>VolumeName</key>
        <string>ReadOnlyAPFS</string>
        <key>TotalSize</key>
        <integer>500000000000</integer>
        <key>APFSContainerFree</key>
        <integer>200000000000</integer>
    </dict>
    </plist>
    """

    static let samsungT7Plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>MountPoint</key>
        <string>/Volumes/SamsungT7</string>
        <key>Internal</key>
        <false/>
        <key>FilesystemType</key>
        <string>apfs</string>
        <key>WritableVolume</key>
        <true/>
        <key>BusProtocol</key>
        <string>USB</string>
        <key>VolumeName</key>
        <string>SamsungT7</string>
        <key>TotalSize</key>
        <integer>1000000000000</integer>
        <key>APFSContainerFree</key>
        <integer>800000000000</integer>
    </dict>
    </plist>
    """

    func testEligibleExternalVolumeFixture() throws {
        let info = try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")
        let manager = VolumeManager()
        let check = manager.eligibilityCheck(for: info)
        XCTAssertTrue(check.isEligible)
        XCTAssertNil(check.reason)
        XCTAssertEqual(info.volumeName, "ExternalSSD")
        XCTAssertEqual(info.filesystemType, "apfs")
        XCTAssertTrue(info.isWritableVolume)
        XCTAssertFalse(info.isInternal)
    }

    func testInstallerDmgIsExcluded() throws {
        let info = try SystemDiskInfoProvider.parsePlist(Self.installerDmgPlist, fallbackPath: "/Volumes/ExampleInstallerDMG")
        let manager = VolumeManager()
        let check = manager.eligibilityCheck(for: info)
        XCTAssertFalse(check.isEligible)
        XCTAssertEqual(check.reason, "Disk image volumes are not supported")
    }

    func testInternalVolumeIsExcluded() throws {
        let info = try SystemDiskInfoProvider.parsePlist(Self.internalVolumePlist, fallbackPath: "/Volumes/InternalData")
        let manager = VolumeManager()
        let check = manager.eligibilityCheck(for: info)
        XCTAssertFalse(check.isEligible)
        XCTAssertEqual(check.reason, "Volume is internal")
    }

    func testNonApfsVolumeIsExcluded() throws {
        let info = try SystemDiskInfoProvider.parsePlist(Self.nonApfsPlist, fallbackPath: "/Volumes/ExFATDrive")
        let manager = VolumeManager()
        let check = manager.eligibilityCheck(for: info)
        XCTAssertFalse(check.isEligible)
        XCTAssertTrue(check.reason?.contains("not apfs") == true)
    }

    func testReadOnlyVolumeIsExcluded() throws {
        let info = try SystemDiskInfoProvider.parsePlist(Self.readOnlyPlist, fallbackPath: "/Volumes/ReadOnlyAPFS")
        let manager = VolumeManager()
        let check = manager.eligibilityCheck(for: info)
        XCTAssertFalse(check.isEligible)
        XCTAssertEqual(check.reason, "Volume is read-only")
    }

    func testSingleEligibleVolumeIsAutoSelected() throws {
        let mock = MockDiskInfoProvider([
            "/Volumes/ExternalSSD": try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD"),
            "/Volumes/ExampleInstallerDMG": try SystemDiskInfoProvider.parsePlist(Self.installerDmgPlist, fallbackPath: "/Volumes/ExampleInstallerDMG")
        ])
        let manager = VolumeManager(
            fileManager: MockFileManager(mountedPaths: ["/Volumes/ExternalSSD", "/Volumes/ExampleInstallerDMG"]),
            diskInfoProvider: mock
        )

        let (eligible, warnings) = try manager.externalVolumesWithWarnings()
        XCTAssertEqual(eligible.count, 1)
        XCTAssertEqual(eligible[0].name, "ExternalSSD")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("ExampleInstallerDMG"))
        XCTAssertTrue(warnings[0].contains("Disk image volumes are not supported"))

        let resolved = try manager.resolveExternalVolume(path: nil)
        XCTAssertEqual(resolved.name, "ExternalSSD")
        XCTAssertEqual(resolved.path, "/Volumes/ExternalSSD")
    }

    func testMultipleEligibleVolumesRequireVolumeOption() throws {
        let mock = MockDiskInfoProvider([
            "/Volumes/ExternalSSD": try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD"),
            "/Volumes/SamsungT7": try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")
        ])
        let manager = VolumeManager(
            fileManager: MockFileManager(mountedPaths: ["/Volumes/ExternalSSD", "/Volumes/SamsungT7"]),
            diskInfoProvider: mock
        )

        let eligible = try manager.externalVolumes()
        XCTAssertEqual(eligible.count, 2)

        XCTAssertThrowsError(try manager.resolveExternalVolume(path: nil)) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume error, got \(error)")
            }
            XCTAssertTrue(message.contains("Multiple eligible external volumes found"))
            XCTAssertTrue(message.contains("--volume"))
        }

        let explicit = try manager.resolveExternalVolume(path: "/Volumes/SamsungT7")
        XCTAssertEqual(explicit.name, "SamsungT7")
        XCTAssertEqual(explicit.path, "/Volumes/SamsungT7")
    }

    func testExplicitVolumeMustPassEligibility() throws {
        let mock = MockDiskInfoProvider([
            "/Volumes/ExampleInstallerDMG": try SystemDiskInfoProvider.parsePlist(Self.installerDmgPlist, fallbackPath: "/Volumes/ExampleInstallerDMG"),
            "/Volumes/InternalData": try SystemDiskInfoProvider.parsePlist(Self.internalVolumePlist, fallbackPath: "/Volumes/InternalData")
        ])
        let manager = VolumeManager(diskInfoProvider: mock)

        XCTAssertThrowsError(try manager.resolveExternalVolume(path: "/Volumes/ExampleInstallerDMG")) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume error, got \(error)")
            }
            XCTAssertTrue(message.contains("Disk image volumes are not supported"))
        }

        XCTAssertThrowsError(try manager.resolveExternalVolume(path: "/Volumes/InternalData")) { error in
            guard case let MacBayError.externalVolumeRequired(message) = error else {
                return XCTFail("Expected externalVolumeRequired error, got \(error)")
            }
            XCTAssertTrue(message.contains("internal"))
        }
    }
}

final class MockDiskInfoProvider: DiskInfoProvider, @unchecked Sendable {
    var mapping: [String: VolumeDiskInfo]

    init(_ mapping: [String: VolumeDiskInfo]) {
        self.mapping = mapping
    }

    func diskInfo(for path: String) throws -> VolumeDiskInfo {
        if let info = mapping[path] {
            return info
        }
        for (key, val) in mapping {
            if path.hasPrefix(key) {
                return val
            }
        }
        throw MacBayError.invalidVolume("Path not in mock: \(path)")
    }
}

final class MockFileManager: FileManager, @unchecked Sendable {
    let mountedPaths: [String]

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
