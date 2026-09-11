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
        <key>VolumeUUID</key>
        <string>E1B2C3D4-0000-1111-2222-333344445555</string>
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
        <key>VolumeUUID</key>
        <string>A1B2C3D4-9999-8888-7777-666655554444</string>
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

    func testVolumeUUIDIsParsedFromDiskInfo() throws {
        let info = try SystemDiskInfoProvider.parsePlist(
            Self.eligibleExternalVolumePlist,
            fallbackPath: "/Volumes/ExternalSSD"
        )
        XCTAssertEqual(info.volumeUUID, "E1B2C3D4-0000-1111-2222-333344445555")

        let withoutUUID = try SystemDiskInfoProvider.parsePlist(
            Self.nonApfsPlist,
            fallbackPath: "/Volumes/ExFATDrive"
        )
        XCTAssertNil(withoutUUID.volumeUUID)
    }

    func testExplicitPathTakesPriorityOverConfiguredDefault() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExternalSSD", "/Volumes/SamsungT7"],
            infos: [
                try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD"),
                try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")
            ]
        )

        let selection = try manager.resolveExternalVolume(
            path: "/Volumes/SamsungT7",
            configuredDefault: makeDefaultVolume()
        )

        XCTAssertEqual(selection.volume.path, "/Volumes/SamsungT7")
        XCTAssertEqual(selection.source, .explicit)
        XCTAssertTrue(selection.warnings.isEmpty)
    }

    func testConfiguredDefaultMatchingSavedPathIsUsed() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExternalSSD", "/Volumes/SamsungT7"],
            infos: [
                try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD"),
                try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")
            ]
        )

        let selection = try manager.resolveExternalVolume(path: nil, configuredDefault: makeDefaultVolume())

        XCTAssertEqual(selection.volume.path, "/Volumes/ExternalSSD")
        XCTAssertEqual(selection.volume.name, "ExternalSSD")
        XCTAssertEqual(selection.source, .configured)
        XCTAssertTrue(selection.warnings.isEmpty)
    }

    func testConfiguredDefaultIsFoundByUUIDWhenMountPathChanged() throws {
        let renamed = VolumeDiskInfo(
            mountPoint: "/Volumes/ExternalSSD 1",
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: "ExternalSSD 1",
            totalBytes: 999_995_129_856,
            availableBytes: 923_864_829_952,
            volumeUUID: "E1B2C3D4-0000-1111-2222-333344445555"
        )
        let manager = makeManager(mountedPaths: [renamed.mountPoint], infos: [renamed])

        let selection = try manager.resolveExternalVolume(path: nil, configuredDefault: makeDefaultVolume())

        XCTAssertEqual(selection.volume.path, "/Volumes/ExternalSSD 1")
        XCTAssertEqual(selection.source, .configured)
        XCTAssertEqual(selection.warnings.count, 1)
        XCTAssertTrue(selection.warnings[0].contains("mounted at /Volumes/ExternalSSD 1"))
        XCTAssertTrue(selection.warnings[0].contains("/Volumes/ExternalSSD"))
    }

    func testConfiguredDefaultNotMountedThrows() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/SamsungT7"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")]
        )

        XCTAssertThrowsError(try manager.resolveExternalVolume(path: nil, configuredDefault: makeDefaultVolume())) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume error, got \(error)")
            }
            XCTAssertTrue(message.contains("is not mounted"))
            XCTAssertTrue(message.contains("/Volumes/ExternalSSD"))
            XCTAssertTrue(message.contains("mb init"))
        }
    }

    func testConfiguredDefaultIsNotSilentlyReplacedByAnotherVolume() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/SamsungT7"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")]
        )

        XCTAssertEqual(manager.availability(of: makeDefaultVolume()), .notMounted)
        XCTAssertThrowsError(try manager.resolveExternalVolume(path: nil, configuredDefault: makeDefaultVolume()))
    }

    func testConfiguredDefaultIneligibleThrows() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ReadOnlyAPFS"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.readOnlyPlist, fallbackPath: "/Volumes/ReadOnlyAPFS")]
        )

        let configured = makeDefaultVolume(path: "/Volumes/ReadOnlyAPFS", name: "ReadOnlyAPFS", uuid: nil)
        XCTAssertThrowsError(try manager.resolveExternalVolume(path: nil, configuredDefault: configured)) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume error, got \(error)")
            }
            XCTAssertTrue(message.contains("is not eligible"))
            XCTAssertTrue(message.contains("read-only"))
            XCTAssertTrue(message.contains("mb init"))
        }
    }

    func testAvailabilityDistinguishesMountedStates() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExFATDrive"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.nonApfsPlist, fallbackPath: "/Volumes/ExFATDrive")]
        )

        let availability = manager.availability(
            of: makeDefaultVolume(path: "/Volumes/ExFATDrive", name: "ExFATDrive", uuid: nil)
        )
        guard case let .ineligible(mountPoint, reason) = availability else {
            return XCTFail("Expected ineligible, got \(availability)")
        }
        XCTAssertEqual(mountPoint, "/Volumes/ExFATDrive")
        XCTAssertTrue(reason.contains("not apfs"))

        XCTAssertEqual(manager.availability(of: makeDefaultVolume()), .notMounted)
    }

    func testAvailabilityReportsMountedConfiguredVolume() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExternalSSD"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")]
        )

        let availability = manager.availability(of: makeDefaultVolume())
        guard case let .mounted(volume, pathChanged) = availability else {
            return XCTFail("Expected mounted, got \(availability)")
        }
        XCTAssertEqual(volume.path, "/Volumes/ExternalSSD")
        XCTAssertFalse(pathChanged)
    }

    func testConfiguredVolumeHasPriorityOverAutoDetection() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExternalSSD"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD")]
        )

        XCTAssertEqual(
            try manager.resolveExternalVolume(path: nil, configuredDefault: nil).source,
            .autoDetected
        )
        XCTAssertEqual(
            try manager.resolveExternalVolume(path: nil, configuredDefault: makeDefaultVolume()).source,
            .configured
        )
    }

    func testMultipleVolumesWithoutConfiguredDefaultSuggestsInit() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/ExternalSSD", "/Volumes/SamsungT7"],
            infos: [
                try SystemDiskInfoProvider.parsePlist(Self.eligibleExternalVolumePlist, fallbackPath: "/Volumes/ExternalSSD"),
                try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")
            ]
        )

        XCTAssertThrowsError(try manager.resolveExternalVolume(path: nil, configuredDefault: nil)) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume error, got \(error)")
            }
            XCTAssertTrue(message.contains("Multiple eligible external volumes"))
            XCTAssertTrue(message.contains("mb init"))
        }
    }

    func testConfiguredDefaultWithUnknownUUIDIsNotMounted() throws {
        let manager = makeManager(
            mountedPaths: ["/Volumes/SamsungT7"],
            infos: [try SystemDiskInfoProvider.parsePlist(Self.samsungT7Plist, fallbackPath: "/Volumes/SamsungT7")]
        )

        let stale = makeDefaultVolume(uuid: "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(manager.availability(of: stale), .notMounted)
    }

    private func makeDefaultVolume(
        path: String = "/Volumes/ExternalSSD",
        name: String = "ExternalSSD",
        uuid: String? = "E1B2C3D4-0000-1111-2222-333344445555"
    ) -> DefaultVolume {
        DefaultVolume(path: path, name: name, uuid: uuid, savedAt: "2026-09-10T12:00:00Z")
    }

    private func makeManager(mountedPaths: [String], infos: [VolumeDiskInfo]) -> VolumeManager {
        let mapping = Dictionary(uniqueKeysWithValues: infos.map { ($0.mountPoint, $0) })
        return VolumeManager(
            fileManager: MockFileManager(mountedPaths: mountedPaths),
            diskInfoProvider: MockDiskInfoProvider(mapping)
        )
    }
}

final class MockDiskInfoProvider: DiskInfoProvider, @unchecked Sendable {
    var mapping: [String: VolumeDiskInfo]

    init(_ mapping: [String: VolumeDiskInfo]) {
        self.mapping = mapping
    }

    func diskInfo(for path: String) throws -> VolumeDiskInfo {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let info = mapping[path] ?? mapping[stdPath] {
            return info
        }
        for (key, val) in mapping.sorted(by: { $0.key.count > $1.key.count }) {
            let stdKey = URL(fileURLWithPath: key).standardizedFileURL.path
            if path.hasPrefix(key) || stdPath.hasPrefix(stdKey) || path.hasPrefix(stdKey) || stdPath.hasPrefix(key) {
                return val
            }
        }
        throw MacBayError.invalidVolume("Path not in mock: \(path)")
    }
}

final class MockFileManager: FileManager, @unchecked Sendable {
    let mountedPaths: [String]
    var unreadableLinkPaths: Set<String> = []
    var unreadableDirectoryPaths: Set<String> = []

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

    override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        if unreadableLinkPaths.contains(path) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
            )
        }
        return try super.destinationOfSymbolicLink(atPath: path)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if unreadableDirectoryPaths.contains(url.path) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
            )
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
