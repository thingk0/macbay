import Foundation
import XCTest
@testable import MacBayKit

final class XcodeStoragePlanTests: XCTestCase {
    private final class Runner: CommandRunner, @unchecked Sendable {
        var running = false
        var processCheckStatus: Int32?
        var simulators: [String] = ["unavailable-device"]
        var simulatorFailure = false
        var copyFailureName: String?
        var mutationCalls: [String] = []
        var simulatorCalls: [[String]] = []
        var simulatorListingFails = false
        var hasOpenFiles = false

        func run(_ executable: String, arguments: [String]) throws -> CommandResult {
            if executable.hasSuffix("pgrep") { return CommandResult(status: processCheckStatus ?? (running ? 0 : 1)) }
            if executable.hasSuffix("lsof") {
                return hasOpenFiles ? CommandResult(status: 0, standardOutput: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nSimulator 123 tester 4u REG 1,1 0 1 " + (arguments.last ?? "")) : CommandResult(status: 1)
            }
            if executable.hasSuffix("ditto") {
                let source = arguments[arguments.count - 2]
                mutationCalls.append("copy:" + source)
                if URL(fileURLWithPath: source).lastPathComponent == copyFailureName {
                    return CommandResult(status: 1, standardError: "Copy denied")
                }
                try FileManager.default.copyItem(atPath: source, toPath: arguments.last!)
                return CommandResult(status: 0)
            }
            if arguments.first == "simctl" { simulatorCalls.append(arguments) }
            if simulatorListingFails, arguments.contains("list") { return CommandResult(status: 1) }
            if arguments.contains("delete") {
                mutationCalls.append("delete unavailable")
                return CommandResult(status: simulatorFailure ? 1 : 0, standardOutput: simulatorFailure ? "Simulator deletion failed" : "Deleted")
            }
            let devices = ["devices": ["runtime": simulators.map { ["udid": $0, "isAvailable": false] as [String: Any] }]]
            let data = try JSONSerialization.data(withJSONObject: devices)
            return CommandResult(status: 0, standardOutput: String(decoding: data, as: UTF8.self))
        }
    }

    private final class Disks: DiskInfoProvider, @unchecked Sendable {
        var info: VolumeDiskInfo!
        var unavailable = false
        func diskInfo(for path: String) throws -> VolumeDiskInfo {
            if unavailable { throw MacBayError.invalidVolume("Drive is disconnected") }
            return info
        }
    }

    private final class RemovalFailure: FileManager, @unchecked Sendable {
        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent == "locked.bin" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try super.removeItem(at: URL)
        }
    }

    private var root: URL!
    private var home: URL!
    private var volume: URL!
    private var runner: Runner!
    private var disks: Disks!
    private var history: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? root.path)
        home = root.appendingPathComponent("home")
        volume = root.appendingPathComponent("volumes/External")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        runner = Runner()
        disks = Disks()
        disks.info = diskInfo()
        history = HistoryStore(environment: [:], homeDirectory: home)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func diskInfo(uuid: String = "external-drive", available: UInt64 = 1_000_000,
                          writable: Bool = true) -> VolumeDiskInfo {
        VolumeDiskInfo(mountPoint: volume.path, isInternal: false, filesystemType: "apfs", isWritableVolume: writable,
                       busProtocol: "USB", volumeName: "External", totalBytes: 2_000_000,
                       availableBytes: available, volumeUUID: uuid)
    }

    private func service(fileManager: FileManager = .default) -> MacBayService {
        let manager = VolumeManager(fileManager: fileManager, diskInfoProvider: disks, volumeMountPrefix: root.appendingPathComponent("volumes").path)
        let doctor = XcodeDoctor(fileManager: fileManager, commandRunner: runner, volumeManager: manager, homeDirectory: home)
        return MacBayService(fileManager: fileManager, commandRunner: runner, volumeManager: manager,
                             configStore: ConfigStore(environment: [:], homeDirectory: home),
                             historyStore: history, xcodeDoctor: doctor)
    }

    @discardableResult
    private func payload(_ directory: String, file: String = "data.bin", bytes: Int = 1024) throws -> URL {
        let dir = home.appendingPathComponent("Library/Developer/Xcode/" + directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func assertStale(_ plan: XcodeStoragePlan, service: MacBayService,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try service.executeXcode(plan: plan), file: file, line: line) { error in
            XCTAssertTrue(error is XcodePlanError, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("fresh preview"), file: file, line: line)
        }
        XCTAssertTrue(runner.mutationCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(history.entries().isEmpty, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.historyURL.path), file: file, line: line)
    }

    func testPreviewIsReadOnlyAndExecutionUsesExactlySelectedOptions() throws {
        let device = try payload("iOS DeviceSupport", bytes: 1024)
        let archive = try payload("Archives", bytes: 2048)
        let derived = try payload("DerivedData", bytes: 512)
        let service = service()
        let options = XcodeDoctorOptions(externalizeDerivedData: true, cleanDerivedData: true)
        let plan = try service.planXcode(volumePath: volume.path, options: options)
        XCTAssertEqual(plan.options, options)
        XCTAssertEqual(plan.volumePath, volume.path)
        XCTAssertEqual(plan.requiredBytes, 3584)
        XCTAssertEqual(plan.report.freedBytes, 512)
        XCTAssertEqual(plan.unavailableSimulatorIDs, ["unavailable-device"])
        XCTAssertTrue(runner.mutationCalls.isEmpty)
        for file in [device, archive, derived] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.stateDirectory.path))
        let result = try service.executeXcode(plan: plan)
        XCTAssertFalse(result.hasFailures, result.failedActions.map(\.reason).joined(separator: "\n"))
        XCTAssertEqual(result.freedBytes, 512)
        XCTAssertEqual(runner.mutationCalls.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.archives).destinationPath + "/data.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: derived.deletingLastPathComponent().path))
        XCTAssertEqual(history.entries().count, 1)
        XCTAssertEqual(history.entries()[0].command, "xcode")
        XCTAssertEqual(history.entries()[0].outcome, .success)
        XCTAssertEqual(history.entries()[0].detail, options.actionDescriptions.joined(separator: ", "))
    }

    func testRunningXcodeBlocksPreviewUnlessForceIsExplicit() throws {
        runner.running = true
        let service = service()
        XCTAssertThrowsError(try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions()))
        XCTAssertTrue(runner.mutationCalls.isEmpty)
        let forced = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions(force: true))
        XCTAssertTrue(forced.xcodeRunning)
        XCTAssertTrue(forced.options.force)
        XCTAssertTrue(runner.mutationCalls.isEmpty)
        _ = try service.executeXcode(plan: forced)
        XCTAssertEqual(runner.mutationCalls, ["delete unavailable"])
    }

    func testXcodeStartingOrChangingForcedStateRequiresFreshPreview() throws {
        for force in [false, true] {
            runner.running = false
            let service = service()
            let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions(force: force))
            runner.running = true
            assertStale(plan, service: service)
        }
    }

    func testUnavailableReadOnlyAndReplacedVolumesStopBeforeMutation() throws {
        let service = service()
        for changed in ["disconnected", "read-only", "replaced"] {
            disks.unavailable = false
            disks.info = diskInfo()
            let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
            if changed == "disconnected" { disks.unavailable = true }
            if changed == "read-only" { disks.info = diskInfo(writable: false) }
            if changed == "replaced" { disks.info = diskInfo(uuid: "different-drive") }
            assertStale(plan, service: service)
        }
    }

    func testInvalidVolumeCannotProduceAPlanOrWriteHistory() throws {
        let service = service()
        disks.info = diskInfo(writable: false)
        XCTAssertThrowsError(try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions()))
        disks.unavailable = true
        XCTAssertThrowsError(try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions()))
        XCTAssertTrue(runner.mutationCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.stateDirectory.path))
    }

    func testInsufficientSpaceAtPreviewAndExecutionIsRejected() throws {
        _ = try payload("Archives", bytes: 1024)
        let service = service()
        disks.info = diskInfo(available: 1)
        XCTAssertThrowsError(try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions()))
        disks.info = diskInfo()
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        disks.info = diskInfo(available: 1)
        assertStale(plan, service: service)
    }

    func testSameSizeEditsAndNewDestinationsRequireFreshPreview() throws {
        let file = try payload("Archives")
        let service = service()
        var plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        try Data(repeating: 2, count: 1024).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        assertStale(plan, service: service)
        plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        try FileManager.default.createDirectory(at: MacBayPaths.xcodeArchivesRoot(on: volume), withIntermediateDirectories: true)
        assertStale(plan, service: service)
    }

    func testLinkedDataChangesAndLinkReplacementsRequireFreshPreview() throws {
        let existing = try payload("Archives")
        let external = volume.appendingPathComponent("LegacyArchives")
        try FileManager.default.moveItem(at: existing.deletingLastPathComponent(), to: external)
        try FileManager.default.createSymbolicLink(at: existing.deletingLastPathComponent(), withDestinationURL: external)
        let service = service()
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        let edited = external.appendingPathComponent("data.bin")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: edited.path)
        assertStale(plan, service: service)
        let current = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        try FileManager.default.removeItem(at: existing.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        assertStale(current, service: service)
    }

    func testChangedSimulatorTargetsAndProcessCheckFailureStopExecution() throws {
        let service = service()
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        runner.simulators.append("new-device")
        assertStale(plan, service: service)
        runner.simulators = ["unavailable-device"]
        runner.processCheckStatus = 2
        assertStale(plan, service: service)
    }

    func testCopyAndSimulatorFailuresPreserveCompletedActionsAndPartialHistory() throws {
        let device = try payload("iOS DeviceSupport")
        let archive = try payload("Archives")
        runner.copyFailureName = "Archives"
        runner.simulatorFailure = true
        let service = service()
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions())
        let result = try service.executeXcode(plan: plan)
        XCTAssertTrue(result.hasFailures)
        XCTAssertNotNil(result.deviceSupport)
        XCTAssertNil(result.archives)
        XCTAssertEqual(result.failedActions.count, 1)
        XCTAssertTrue(result.failedActions[0].reason.contains("Copy denied"))
        XCTAssertEqual(result.simulatorCleanup?.succeeded, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.path)) // Link resolves to copied data.
        XCTAssertEqual(history.entries().count, 1)
        XCTAssertEqual(history.entries()[0].outcome, .partial)
    }

    func testPartialCleanupReportsOnlySuccessfullyRemovedBytes() throws {
        let removed = try payload("DerivedData", bytes: 256)
        let locked = try payload("DerivedData", file: "locked.bin", bytes: 512)
        let service = service(fileManager: RemovalFailure())
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions(cleanDerivedData: true))
        XCTAssertEqual(plan.report.freedBytes, 768)
        let result = try service.executeXcode(plan: plan)
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.freedBytes, 256)
        XCTAssertEqual(result.derivedDataCleanup?.succeeded, false)
        XCTAssertTrue(result.derivedDataCleanup?.output.contains("locked.bin") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertEqual(history.entries()[0].outcome, .partial)
    }

    func testNewlyManagedXcodeDataCanBeRestoredThroughUnmove() throws {
        let archive = try payload("Archives")
        let source = archive.deletingLastPathComponent()
        let service = service(fileManager: MockFileManager(mountedPaths: [volume.path]))
        let plan = try service.planXcode(volumePath: volume.path, options: XcodeDoctorOptions(deleteUnavailableSimulators: false))
        let report = try service.executeXcode(plan: plan)
        let external = try XCTUnwrap(report.archives).destinationPath
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        _ = try service.unmove(path: source.path, volumePath: volume.path, dryRun: false)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external))
        XCTAssertTrue(try ManifestStore().load(on: volume).items.isEmpty)
        XCTAssertTrue(OperationJournal().listIncompleteMoves(on: volume).isEmpty)
    }

    func testSimulatorCleanupIsOptionalAndDoesNotRequireSimulatorToolsWhenOff() throws {
        _ = try payload("Archives")
        runner.simulatorListingFails = true
        let service = service()
        let options = XcodeDoctorOptions(deleteUnavailableSimulators: false)
        let plan = try service.planXcode(volumePath: volume.path, options: options)
        XCTAssertTrue(plan.unavailableSimulatorIDs.isEmpty)
        XCTAssertNil(plan.report.simulatorCleanup)
        XCTAssertFalse(options.actionDescriptions.contains("delete unavailable simulators"))
        let report = try service.executeXcode(plan: plan)
        XCTAssertFalse(report.hasFailures, report.failedActions.map(\.reason).joined(separator: "\n"))
        XCTAssertTrue(runner.simulatorCalls.isEmpty)
        XCTAssertEqual(try ManifestStore().load(on: volume).items.count, 1)
    }

    func testExecutionDeletesOnlyReviewedSimulatorIDsAndSkipsAnEmptyList() throws {
        let service = service()
        let options = XcodeDoctorOptions(externalizeDeviceSupport: false, externalizeArchives: false)
        let plan = try service.planXcode(volumePath: volume.path, options: options)
        _ = try service.executeXcode(plan: plan)
        XCTAssertTrue(runner.simulatorCalls.contains(["simctl", "delete", "unavailable-device"]))
        XCTAssertFalse(runner.simulatorCalls.contains(["simctl", "delete", "unavailable"]))
        runner.mutationCalls.removeAll()
        runner.simulators = []
        let empty = try service.planXcode(volumePath: volume.path, options: options)
        let report = try service.executeXcode(plan: empty)
        XCTAssertFalse(report.hasFailures)
        XCTAssertTrue(runner.mutationCalls.isEmpty)
    }

    func testDeviceSupportOnlyAlsoRequiresXcodeToBeClosed() throws {
        _ = try payload("iOS DeviceSupport")
        runner.running = true
        XCTAssertThrowsError(try service().planXcode(volumePath: volume.path,
            options: XcodeDoctorOptions(externalizeArchives: false, deleteUnavailableSimulators: false)))
        XCTAssertTrue(runner.mutationCalls.isEmpty)
    }

    func testCleanupRefusesLinksToUnmanagedDataAndLeavesAllFilesUntouched() throws {
        let important = home.appendingPathComponent("Important")
        try FileManager.default.createDirectory(at: important, withIntermediateDirectories: true)
        let archive = important.appendingPathComponent("archive.bin")
        try Data("irreplaceable".utf8).write(to: archive)
        let source = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: important)
        XCTAssertThrowsError(try service().planXcode(volumePath: volume.path,
            options: XcodeDoctorOptions(externalizeDeviceSupport: false, externalizeArchives: false,
                cleanDerivedData: true, deleteUnavailableSimulators: false)))
        XCTAssertEqual(try Data(contentsOf: archive), Data("irreplaceable".utf8))
        XCTAssertTrue(runner.mutationCalls.isEmpty)
    }

    func testOpenFilesBlockCleanupBeforeDeletingAnyBuildData() throws {
        let file = try payload("DerivedData")
        runner.hasOpenFiles = true
        XCTAssertThrowsError(try service().planXcode(volumePath: volume.path,
            options: XcodeDoctorOptions(externalizeDeviceSupport: false, externalizeArchives: false,
                cleanDerivedData: true, deleteUnavailableSimulators: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(runner.mutationCalls.isEmpty)
    }

    func testReportsDecodeOldJSONAndPreserveNewFailures() throws {
        let old = try JSONDecoder().decode(XcodeDoctorReport.self, from: Data("{\"freedBytes\":12}".utf8))
        XCTAssertEqual(old.failedActions, [])
        let result = XcodeDoctorReport(failedActions: [XcodeActionFailure(action: "Archives", reason: "Denied")])
        XCTAssertEqual(try JSONDecoder().decode(XcodeDoctorReport.self, from: JSONEncoder().encode(result)), result)
        XCTAssertTrue(OutputFormatter().xcode(result).contains("Failed: Archives: Denied"))
    }
}
