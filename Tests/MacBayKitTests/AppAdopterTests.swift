import Foundation
import XCTest
@testable import MacBayKit

final class AppAdopterTests: XCTestCase {
    private var tempDir: URL!
    private var appsDir: URL!
    private var volumeURL: URL!
    private var mockDisk: MockDiskInfoProvider!
    private var volumeManager: VolumeManager!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macbay-adopter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        appsDir = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        volumeURL = tempDir.appendingPathComponent("Volumes/ExternalSSD")
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)

        let diskInfo = VolumeDiskInfo(
            mountPoint: volumeURL.path,
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: "ExternalSSD",
            totalBytes: 1_000_000_000_000,
            availableBytes: 900_000_000_000,
            volumeUUID: "E1B2C3D4-0000-1111-2222-333344445555"
        )
        let internalInfo = VolumeDiskInfo(
            mountPoint: "/",
            isInternal: true,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "Apple Fabric",
            volumeName: "Macintosh HD",
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000
        )
        mockDisk = MockDiskInfoProvider([
            volumeURL.path: diskInfo,
            "/": internalInfo
        ])
        volumeManager = VolumeManager(diskInfoProvider: mockDisk, volumeMountPrefix: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeAdopter(runner: (any CommandRunner)? = nil) -> AppAdopter {
        let cmdRunner = runner ?? TestBundleCommandRunner(entitlementsXml: "")
        return AppAdopter(
            fileManager: .default,
            commandRunner: cmdRunner,
            volumeManager: volumeManager
        )
    }

    private func createAppBundle(at url: URL, executableName: String = "TestApp") throws {
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

    func testAdoptNormalMoveOutsideStandardPath() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/ChatGPT.app")
        try createAppBundle(at: externalApp, executableName: "ChatGPT")
        let linkURL = appsDir.appendingPathComponent("ChatGPT.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: false)

        XCTAssertEqual(result.operation, "adopt")
        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.name, "ChatGPT.app")

        let expectedDestination = volumeURL.appendingPathComponent("MacBay/Applications/ChatGPT.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalApp.path))

        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        XCTAssertEqual(URL(fileURLWithPath: linkTarget).standardizedFileURL.path, expectedDestination.standardizedFileURL.path)

        let manifest = try ManifestStore().load(on: volumeURL)
        XCTAssertEqual(manifest.items.count, 1)
        let item = manifest.items[0]
        XCTAssertEqual(item.name, "ChatGPT.app")
        XCTAssertEqual(item.sourcePath, linkURL.path)
        XCTAssertEqual(item.externalPath, expectedDestination.path)

        let journal = OperationJournal()
        XCTAssertEqual(journal.listIncompleteOperations(on: volumeURL).count, 0)
    }

    func testAdoptRegisterOnlyWhenAlreadyInStandardPath() throws {
        let standardApp = volumeURL.appendingPathComponent("MacBay/Applications/ChatGPT.app")
        try createAppBundle(at: standardApp, executableName: "ChatGPT")
        let linkURL = appsDir.appendingPathComponent("ChatGPT.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: standardApp)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: false)

        XCTAssertEqual(result.operation, "adopt")
        XCTAssertTrue(result.messages.contains { $0.contains("registered in manifest") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: standardApp.path))

        let manifest = try ManifestStore().load(on: volumeURL)
        XCTAssertEqual(manifest.items.count, 1)
        XCTAssertEqual(manifest.items[0].externalPath, standardApp.path)
    }

    func testAdoptIdempotentWhenAlreadyAdopted() throws {
        let standardApp = volumeURL.appendingPathComponent("MacBay/Applications/ChatGPT.app")
        try createAppBundle(at: standardApp, executableName: "ChatGPT")
        let linkURL = appsDir.appendingPathComponent("ChatGPT.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: standardApp)

        let manifestStore = ManifestStore()
        try manifestStore.save(DockManifest(items: [
            DockedItem(
                name: "ChatGPT.app",
                sourcePath: linkURL.path,
                externalPath: standardApp.path,
                sizeBytes: 1024,
                kind: .application,
                dockedAt: macBayTimestamp()
            )
        ]), on: volumeURL)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: false)

        XCTAssertEqual(result.operation, "adopt")
        XCTAssertTrue(result.messages.contains { $0.contains("already adopted") })
    }

    func testAdoptRelativeSymlink() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/RelativeApp.app")
        try createAppBundle(at: externalApp, executableName: "RelativeApp")
        let linkURL = appsDir.appendingPathComponent("RelativeApp.app")

        // Construct relative destination from appsDir to externalApp
        let relativeDest = "../Volumes/ExternalSSD/Applications/RelativeApp.app"
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: relativeDest)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: false)

        XCTAssertEqual(result.operation, "adopt")
        let expectedDestination = volumeURL.appendingPathComponent("MacBay/Applications/RelativeApp.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDestination.path))

        let manifest = try ManifestStore().load(on: volumeURL)
        XCTAssertEqual(manifest.items.count, 1)
    }

    func testAdoptMultiHopRejected() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/MultiHop.app")
        try createAppBundle(at: externalApp, executableName: "MultiHop")

        let intermediateLink = tempDir.appendingPathComponent("Intermediate.app")
        try FileManager.default.createSymbolicLink(at: intermediateLink, withDestinationURL: externalApp)

        let linkURL = appsDir.appendingPathComponent("MultiHop.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: intermediateLink)

        let adopter = makeAdopter()
        XCTAssertThrowsError(try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(msg) = error else {
                return XCTFail("Expected unsupportedOperation for multi-hop, got \(error)")
            }
            XCTAssertTrue(msg.contains("Multi-hop"))
        }
    }

    func testAdoptDestinationExistsThrows() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/Collision.app")
        try createAppBundle(at: externalApp, executableName: "Collision")
        let linkURL = appsDir.appendingPathComponent("Collision.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let existingDest = volumeURL.appendingPathComponent("MacBay/Applications/Collision.app")
        try createAppBundle(at: existingDest, executableName: "Collision")

        let adopter = makeAdopter()
        XCTAssertThrowsError(try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false)) { error in
            guard case MacBayError.destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalApp.path))
    }

    func testAdoptCompatibilityBlockedThrows() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/Blocked.app")
        try createAppBundle(at: externalApp, executableName: "Blocked")
        let linkURL = appsDir.appendingPathComponent("Blocked.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let entitlementsXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
        """
        let runner = TestBundleCommandRunner(entitlementsXml: entitlementsXml)
        let adopter = makeAdopter(runner: runner)

        XCTAssertThrowsError(try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: true)) { error in
            guard case let MacBayError.compatibilityBlocked(_, assessment) = error else {
                return XCTFail("Expected compatibilityBlocked, got \(error)")
            }
            XCTAssertEqual(assessment.grade, .blocked)
        }
    }

    func testAdoptCompatibilityPopupRiskRequiresForce() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/Risk.app")
        try createAppBundle(at: externalApp, executableName: "Risk")
        let linkURL = appsDir.appendingPathComponent("Risk.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        // Write relocation signal in binary to trigger popupRisk
        let execURL = externalApp.appendingPathComponent("Contents/MacOS/Risk")
        try Data("moveToApplicationsFolder".utf8).write(to: execURL)

        let runner = TestBundleCommandRunner(entitlementsXml: "")
        let adopter = makeAdopter(runner: runner)

        // Dry run succeeds without force and includes warning
        let dryResult = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: true, force: false)
        XCTAssertTrue(dryResult.messages.contains { $0.contains("popup risks") })

        // Real run without force throws forceRequired
        XCTAssertThrowsError(try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: false)) { error in
            guard case MacBayError.forceRequired = error else {
                return XCTFail("Expected forceRequired, got \(error)")
            }
        }

        // Real run with force succeeds
        let realResult = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false, force: true)
        XCTAssertEqual(realResult.operation, "adopt")
    }

    func testAdoptCodeSignFailureRollsBack() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/SignFail.app")
        try createAppBundle(at: externalApp, executableName: "SignFail")
        let linkURL = appsDir.appendingPathComponent("SignFail.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let runner = TestBundleCommandRunner(entitlementsXml: "", verifyStatus: 1, verifyStderr: "Corrupted signature")
        let adopter = makeAdopter(runner: runner)

        XCTAssertThrowsError(try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false)) { error in
            guard case MacBayError.signatureVerificationFailed = error else {
                return XCTFail("Expected signatureVerificationFailed, got \(error)")
            }
        }

        // App remains at original path
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalApp.path))
        // Standard destination does not exist
        let standardDest = volumeURL.appendingPathComponent("MacBay/Applications/SignFail.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: standardDest.path))
    }

    func testAdoptNonSymlinkLocalAppThrows() throws {
        let localApp = appsDir.appendingPathComponent("Local.app")
        try createAppBundle(at: localApp, executableName: "Local")

        let adopter = makeAdopter()
        XCTAssertThrowsError(try adopter.adopt(appName: localApp.path, on: volumeURL, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(msg) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(msg.contains("mb dock"))
        }
    }

    func testAdoptDryRunDoesNotModifyFiles() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/DryApp.app")
        try createAppBundle(at: externalApp, executableName: "DryApp")
        let linkURL = appsDir.appendingPathComponent("DryApp.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.messages.contains { $0.contains("internal space freed 0 B") })
        XCTAssertTrue(result.messages.contains { $0.contains("Dry run: no files were changed") })

        // Files remain unmodified
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalApp.path))
        let standardDest = volumeURL.appendingPathComponent("MacBay/Applications/DryApp.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: standardDest.path))

        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        XCTAssertEqual(linkTarget, externalApp.path)
    }

    func testAdoptResumesIncompleteOperationWithBrokenLink() throws {
        // Setup: App was moved to standard path, but link is still pointing to old path
        let oldExternalApp = volumeURL.appendingPathComponent("Applications/Interrupted.app")
        let standardApp = volumeURL.appendingPathComponent("MacBay/Applications/Interrupted.app")
        try createAppBundle(at: standardApp, executableName: "Interrupted")

        let linkURL = appsDir.appendingPathComponent("Interrupted.app")
        // Broken symlink pointing to non-existent old path
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: oldExternalApp)

        // Record operation journal
        let journal = OperationJournal()
        let record = AdoptOperationRecord(
            id: UUID().uuidString,
            appName: "Interrupted.app",
            sourcePath: linkURL.path,
            originalExternalPath: oldExternalApp.path,
            targetExternalPath: standardApp.path,
            originalLinkTarget: oldExternalApp.path,
            volumePath: volumeURL.path,
            phase: .appMoved,
            timestamp: macBayTimestamp()
        )
        try journal.save(record, on: volumeURL)

        let adopter = makeAdopter()
        let result = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false)

        XCTAssertEqual(result.operation, "adopt")
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        XCTAssertEqual(URL(fileURLWithPath: linkTarget).standardizedFileURL.path, standardApp.standardizedFileURL.path)

        let manifest = try ManifestStore().load(on: volumeURL)
        XCTAssertEqual(manifest.items.count, 1)
        XCTAssertEqual(journal.listIncompleteOperations(on: volumeURL).count, 0)
    }

    func testDockUnmanagedLinkSuggestsAdopt() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/Unmanaged.app")
        try createAppBundle(at: externalApp, executableName: "Unmanaged")
        let linkURL = appsDir.appendingPathComponent("Unmanaged.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let runner = TestBundleCommandRunner(entitlementsXml: "")
        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager
        )

        XCTAssertThrowsError(try migrator.dock(appName: linkURL.path, on: volumeURL, dryRun: false)) { error in
            guard case let MacBayError.unmanagedLinkDetected(path, targetPath) = error else {
                return XCTFail("Expected unmanagedLinkDetected, got \(error)")
            }
            XCTAssertEqual(path, linkURL.path)
            XCTAssertEqual(targetPath, externalApp.path)
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("mb adopt"))
        }
    }

    func testAdoptScanStatusDoctorUndockFullLifecycle() throws {
        let externalApp = volumeURL.appendingPathComponent("Applications/LifecycleApp.app")
        try createAppBundle(at: externalApp, executableName: "LifecycleApp")
        let linkURL = appsDir.appendingPathComponent("LifecycleApp.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalApp)

        let runner = TestBundleCommandRunner(entitlementsXml: "")
        let manifestStore = ManifestStore()
        let scanner = AppScanner(
            fileManager: .default,
            commandRunner: runner,
            diskInfoProvider: mockDisk,
            manifestStore: manifestStore
        )

        // 1. Scan before adoption: Unmanaged
        let scanBefore = scanner.scan(
            minimumApplicationSizeBytes: 0,
            applicationDirectories: [appsDir],
            developerCacheTargets: []
        )
        XCTAssertEqual(scanBefore.externalApplications.count, 1)
        XCTAssertEqual(scanBefore.externalApplications[0].managementStatus, .unmanaged)

        // 2. Dock attempt: suggests adopt
        let migrator = BundleMigrator(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager
        )
        XCTAssertThrowsError(try migrator.dock(appName: linkURL.path, on: volumeURL, dryRun: false)) { error in
            guard case MacBayError.unmanagedLinkDetected = error else {
                return XCTFail("Expected unmanagedLinkDetected, got \(error)")
            }
        }

        // 3. Adopt
        let adopter = AppAdopter(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager,
            manifestStore: manifestStore
        )
        let adoptResult = try adopter.adopt(appName: linkURL.path, on: volumeURL, dryRun: false)
        XCTAssertEqual(adoptResult.operation, "adopt")

        // 4. Scan after adoption: MacBay
        let scanAfter = scanner.scan(
            minimumApplicationSizeBytes: 0,
            applicationDirectories: [appsDir],
            developerCacheTargets: []
        )
        XCTAssertEqual(scanAfter.externalApplications.count, 1)
        XCTAssertEqual(scanAfter.externalApplications[0].managementStatus, .macBay)

        // 5. Doctor verification: linkManagedRecord (healthy)
        let checker = DoctorChecker(
            fileManager: .default,
            commandRunner: runner,
            volumeManager: volumeManager,
            manifestStore: manifestStore
        )
        let doctorReport = try checker.check(
            volumePath: volumeURL.path,
            applicationDirectories: [appsDir],
            developerCacheTargets: []
        )
        let appFinding = doctorReport.findings.first { $0.name == "LifecycleApp.app" }
        XCTAssertEqual(appFinding?.code, .linkManagedRecord)
        XCTAssertEqual(appFinding?.status, .healthy)

        // 6. Undock restoration
        let undockResult = try migrator.undock(appName: linkURL.path, from: volumeURL, dryRun: false)
        XCTAssertEqual(undockResult.operation, "undock")

        // Verified: restored to internal applications directory as a real bundle
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path))

        // Verified: external standard path removed and manifest updated
        let standardApp = volumeURL.appendingPathComponent("MacBay/Applications/LifecycleApp.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: standardApp.path))
        let manifest = try manifestStore.load(on: volumeURL)
        XCTAssertEqual(manifest.items.count, 0)
    }
}
