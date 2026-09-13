import Foundation
import XCTest
@testable import MacBayKit

final class MacBayServiceTests: XCTestCase {
    private var tempDir: URL!
    private var configHome: URL!
    private var internalVolume: VolumeDiskInfo!
    private var externalSSD: VolumeDiskInfo!
    private var samsungT7: VolumeDiskInfo!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayServiceTests-\(UUID().uuidString)")
        configHome = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        internalVolume = makeDiskInfo(mountPoint: "/", name: "Macintosh HD", isInternal: true, uuid: "UUID-INTERNAL")
        externalSSD = makeDiskInfo(mountPoint: "/Volumes/ExternalSSD", name: "ExternalSSD", uuid: "UUID-SSD")
        samsungT7 = makeDiskInfo(mountPoint: "/Volumes/SamsungT7", name: "SamsungT7", uuid: "UUID-T7")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeDiskInfo(
        mountPoint: String,
        name: String,
        isInternal: Bool = false,
        isWritable: Bool = true,
        uuid: String?
    ) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: isWritable,
            busProtocol: isInternal ? "Apple Fabric" : "PCI-Express",
            volumeName: name,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000,
            volumeUUID: uuid
        )
    }

    private func makeService(mounted: [VolumeDiskInfo]) -> MacBayService {
        let paths = ["/"] + mounted.map(\.mountPoint)
        let mapping = Dictionary(uniqueKeysWithValues: ([internalVolume] + mounted).map { ($0.mountPoint, $0) })
        let volumeManager = VolumeManager(
            fileManager: MockFileManager(mountedPaths: paths),
            diskInfoProvider: MockDiskInfoProvider(mapping)
        )
        let configStore = ConfigStore(
            environment: ["XDG_CONFIG_HOME": configHome.path],
            homeDirectory: tempDir
        )
        return MacBayService(
            fileManager: MockFileManager(mountedPaths: paths),
            volumeManager: volumeManager,
            configStore: configStore,
            historyStore: makeHistoryStore()
        )
    }

    /// History written by the service stays inside this test's temp directory.
    private func makeHistoryStore() -> HistoryStore {
        HistoryStore(
            environment: ["XDG_STATE_HOME": tempDir.appendingPathComponent("state").path],
            homeDirectory: tempDir
        )
    }

    private func writeCorruptedConfig() throws {
        let configURL = configHome.appendingPathComponent("macbay/config.json")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: configURL)
    }

    func testFailedDockIsRecordedInInjectedHistoryStore() throws {
        let service = makeService(mounted: [externalSSD])

        XCTAssertThrowsError(try service.dock(
            appName: "Missing.app",
            volumePath: "/Volumes/DoesNotExist",
            dryRun: false
        ))

        let entries = service.history()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.command, "dock")
        XCTAssertEqual(entries.first?.outcome, .failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: makeHistoryStore().historyURL.path))
    }

    func testCancellationErrorIsRecognized() {
        XCTAssertTrue(MacBayError.cancelled.isCancellation)
        XCTAssertEqual(MacBayError.cancelled, .unsupportedOperation("Cancelled"))
        XCTAssertFalse(MacBayError.unsupportedOperation("Something else").isCancellation)
        XCTAssertFalse(MacBayError.pathMissing("/tmp/x").isCancellation)
    }

    func testInitializeSavesExplicitVolume() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])

        let report = try service.initialize(volumePath: "/Volumes/SamsungT7")

        XCTAssertEqual(report.volume.path, "/Volumes/SamsungT7")
        XCTAssertEqual(report.volume.name, "SamsungT7")
        XCTAssertEqual(report.configPath, configHome.appendingPathComponent("macbay/config.json").path)
        XCTAssertNil(report.previousDefault)
        XCTAssertFalse(report.replaced)

        let saved = try service.showConfig().defaultVolume
        XCTAssertEqual(saved?.path, "/Volumes/SamsungT7")
        XCTAssertEqual(saved?.name, "SamsungT7")
        XCTAssertEqual(saved?.uuid, "UUID-T7")
    }

    func testInitializeSelectsSingleEligibleVolumeAutomatically() throws {
        let service = makeService(mounted: [externalSSD])

        let report = try service.initialize()

        XCTAssertEqual(report.volume.path, "/Volumes/ExternalSSD")
        XCTAssertEqual(try service.showConfig().defaultVolume?.path, "/Volumes/ExternalSSD")
    }

    func testInitializeWithoutChooserFailsForMultipleVolumes() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])

        XCTAssertThrowsError(try service.initialize()) { error in
            guard case let MacBayError.unsupportedOperation(message) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("Multiple eligible external volumes"))
            XCTAssertTrue(message.contains("interactive selection requires a terminal"))
        }

        let config = try? service.showConfig()
        XCTAssertNil(config?.defaultVolume)
    }

    func testInitializeWithChooserSavesSelection() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])
        var offered: [StorageVolume] = []

        let report = try service.initialize(chooser: { volumes in
            offered = volumes
            return 1
        })

        XCTAssertEqual(offered.map(\.path), ["/Volumes/ExternalSSD", "/Volumes/SamsungT7"])
        XCTAssertEqual(report.volume.path, "/Volumes/SamsungT7")
        XCTAssertEqual(try service.showConfig().defaultVolume?.path, "/Volumes/SamsungT7")
    }

    func testInitializeRejectsChooserIndexOutOfRange() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])

        XCTAssertThrowsError(try service.initialize(chooser: { _ in 7 })) { error in
            guard case let MacBayError.unsupportedOperation(message) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertEqual(message, "Cancelled")
        }
    }

    func testInitializeFailsWithoutEligibleVolumes() throws {
        let service = makeService(mounted: [])

        XCTAssertThrowsError(try service.initialize()) { error in
            guard case let MacBayError.invalidVolume(message) = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
            XCTAssertTrue(message.contains("No eligible external APFS volume"))
        }
    }

    func testInitializeRejectsIneligibleExplicitVolume() throws {
        let archive = makeDiskInfo(mountPoint: "/Volumes/Archive", name: "Archive", isWritable: false, uuid: "UUID-ARCHIVE")
        let service = makeService(mounted: [archive])

        XCTAssertThrowsError(try service.initialize(volumePath: "/Volumes/Archive")) { error in
            guard case MacBayError.invalidVolume = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
        }
    }

    func testInitializeReplacesExistingDefaultAfterConfirmation() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])
        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")

        var confirmation: (previous: DefaultVolume, replacement: StorageVolume)?
        let report = try service.initialize(
            volumePath: "/Volumes/SamsungT7",
            confirmReplace: { previous, replacement in
                confirmation = (previous, replacement)
            }
        )

        XCTAssertEqual(report.replaced, true)
        XCTAssertEqual(report.previousDefault?.path, "/Volumes/ExternalSSD")
        XCTAssertEqual(confirmation?.previous.path, "/Volumes/ExternalSSD")
        XCTAssertEqual(confirmation?.replacement.path, "/Volumes/SamsungT7")
        XCTAssertEqual(try service.showConfig().defaultVolume?.path, "/Volumes/SamsungT7")
    }

    func testInitializeSkipsConfirmationForSameVolume() throws {
        let service = makeService(mounted: [externalSSD])
        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")

        var confirmationCalled = false
        let report = try service.initialize(
            volumePath: "/Volumes/ExternalSSD",
            confirmReplace: { _, _ in confirmationCalled = true }
        )

        XCTAssertFalse(confirmationCalled)
        XCTAssertTrue(report.replaced)
    }

    func testInitializeKeepsPreviousDefaultWhenConfirmationCancels() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])
        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")

        XCTAssertThrowsError(
            try service.initialize(
                volumePath: "/Volumes/SamsungT7",
                confirmReplace: { _, _ in throw MacBayError.unsupportedOperation("Cancelled") }
            )
        ) { error in
            guard case MacBayError.unsupportedOperation = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }

        XCTAssertEqual(try service.showConfig().defaultVolume?.path, "/Volumes/ExternalSSD")
    }

    func testShowConfigReportsSavedDefault() throws {
        let service = makeService(mounted: [externalSSD])
        let empty = try service.showConfig()
        XCTAssertEqual(empty.configPath, configHome.appendingPathComponent("macbay/config.json").path)
        XCTAssertNil(empty.defaultVolume)
        XCTAssertNil(empty.removedVolume)

        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")
        XCTAssertEqual(try service.showConfig().defaultVolume?.name, "ExternalSSD")
    }

    func testResetConfigRemovesSavedDefault() throws {
        let service = makeService(mounted: [externalSSD])
        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")

        let report = try service.resetConfig()

        XCTAssertEqual(report.removedVolume?.path, "/Volumes/ExternalSSD")
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.configPath))
        XCTAssertNil(try service.showConfig().defaultVolume)
    }

    func testResetConfigWithoutFileIsNoOp() throws {
        let service = makeService(mounted: [externalSSD])

        let report = try service.resetConfig()

        XCTAssertNil(report.removedVolume)
    }

    func testStatusReportsMountedDefaultVolume() throws {
        let service = makeService(mounted: [externalSSD, samsungT7])
        _ = try service.initialize(volumePath: "/Volumes/ExternalSSD")

        let report = try service.status()

        XCTAssertEqual(report.defaultVolume?.path, "/Volumes/ExternalSSD")
        XCTAssertEqual(report.defaultVolume?.mountedPath, "/Volumes/ExternalSSD")
        XCTAssertEqual(report.defaultVolume?.uuid, "UUID-SSD")
        XCTAssertFalse(report.warnings.contains { $0.contains("not mounted") })
    }

    func testStatusWarnsWhenDefaultVolumeIsUnavailable() throws {
        _ = try makeService(mounted: [externalSSD, samsungT7]).initialize(volumePath: "/Volumes/ExternalSSD")
        let service = makeService(mounted: [samsungT7])

        let report = try service.status()

        XCTAssertEqual(report.defaultVolume?.path, "/Volumes/ExternalSSD")
        XCTAssertNil(report.defaultVolume?.mountedPath)
        XCTAssertTrue(report.warnings.contains { $0.contains("is not mounted") })
    }

    func testStatusWarnsWhenConfigIsUnreadable() throws {
        let service = makeService(mounted: [externalSSD])
        try writeCorruptedConfig()

        let report = try service.status()

        XCTAssertNil(report.defaultVolume)
        XCTAssertTrue(report.warnings.contains { $0.contains("Unable to read MacBay configuration") })
    }

    func testMutatingSelectionFailsWhenConfigIsUnreadable() throws {
        let service = makeService(mounted: [externalSSD])
        try writeCorruptedConfig()

        XCTAssertThrowsError(try service.xcode(volumePath: nil, dryRun: true)) { error in
            guard case MacBayError.configFailed = error else {
                return XCTFail("Expected configFailed, got \(error)")
            }
        }
    }
}
