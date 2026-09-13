import Foundation
import XCTest
@testable import MacBayKit

final class DoctorCheckerTests: XCTestCase {
    private var tempDir: URL!
    private var volumesDir: URL!
    private var appsDir: URL!
    private var volumeDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        let unique = UUID().uuidString
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(FileManager.default.temporaryDirectory.path, &buffer)
        let resolvedTemp = String(cString: buffer)
        tempDir = URL(fileURLWithPath: resolvedTemp).appendingPathComponent("MacBayDoctorTests-\(unique)")
        volumesDir = tempDir.appendingPathComponent("Volumes")
        appsDir = tempDir.appendingPathComponent("Applications")
        volumeDir = volumesDir.appendingPathComponent("ExternalSSD")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeDiskInfo(
        mountPoint: String,
        isInternal: Bool = false,
        isWritableVolume: Bool = true
    ) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: isWritableVolume,
            busProtocol: "PCI-Express",
            volumeName: URL(fileURLWithPath: mountPoint).lastPathComponent,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000
        )
    }

    private func makeChecker(
        mountedPaths: [String]? = nil,
        fileManager: MockFileManager? = nil,
        extraDiskInfo: [String: VolumeDiskInfo] = [:],
        configStore: ConfigStore? = nil
    ) -> DoctorChecker {
        let mounted = mountedPaths ?? [volumeDir.path]
        var mapping: [String: VolumeDiskInfo] = [volumeDir.path: makeDiskInfo(mountPoint: volumeDir.path)]
        for (path, info) in extraDiskInfo {
            mapping[path] = info
        }
        let mockFileManager = fileManager ?? MockFileManager(mountedPaths: mounted)
        let volumeManager = VolumeManager(
            fileManager: mockFileManager,
            diskInfoProvider: MockDiskInfoProvider(mapping),
            volumeMountPrefix: volumesDir.path
        )
        return DoctorChecker(
            fileManager: mockFileManager,
            volumeManager: volumeManager,
            manifestStore: ManifestStore(fileManager: mockFileManager),
            configStore: configStore ?? makeConfigStore()
        )
    }

    private func makeConfigStore() -> ConfigStore {
        ConfigStore(
            environment: ["XDG_CONFIG_HOME": tempDir.appendingPathComponent("config").path],
            homeDirectory: tempDir
        )
    }

    @discardableResult
    private func saveDefaultVolume(path: String, name: String, uuid: String? = nil) throws -> ConfigStore {
        let store = makeConfigStore()
        try store.save(MacBayConfig(defaultVolume: DefaultVolume(
            path: path,
            name: name,
            uuid: uuid,
            savedAt: "2026-09-10T12:00:00Z"
        )))
        return store
    }

    private func check(
        _ checker: DoctorChecker,
        volumePath: String? = nil,
        cacheTargets: [DeveloperCacheTarget] = [],
        fix: Bool = false,
        dryRun: Bool = false
    ) throws -> DoctorReport {
        try checker.check(
            volumePath: volumePath,
            applicationDirectories: [appsDir],
            developerCacheTargets: cacheTargets,
            fix: fix,
            dryRun: dryRun
        )
    }

    private func makeItem(
        name: String,
        sourcePath: String,
        externalPath: String,
        kind: DockedItemKind = .application
    ) -> DockedItem {
        DockedItem(
            name: name,
            sourcePath: sourcePath,
            externalPath: externalPath,
            sizeBytes: 1024,
            kind: kind,
            dockedAt: "2026-09-10T12:00:00Z"
        )
    }

    private func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: url.appendingPathComponent("payload"))
    }

    @discardableResult
    private func saveManifest(
        items: [DockedItem],
        version: Int = DockManifest.currentVersion
    ) throws -> URL {
        let manifestURL = MacBayPaths.manifestURL(on: volumeDir)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(DockManifest(version: version, items: items)).write(to: manifestURL)
        return manifestURL
    }

    private func findings(_ report: DoctorReport, code: DoctorCode) -> [DoctorFinding] {
        report.findings.filter { $0.code == code }
    }

    private func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func testManagedApplicationLinkIsHealthy() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Managed.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Managed.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        try saveManifest(items: [makeItem(
            name: "Managed.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        let managed = try XCTUnwrap(findings(report, code: .linkManagedRecord).first)
        XCTAssertEqual(managed.status, .healthy)
        XCTAssertEqual(managed.managed, true)
        XCTAssertEqual(managed.category, .applicationLink)
        XCTAssertEqual(managed.paths.map(standardPath), [standardPath(link.path), standardPath(externalApp.path)])
        XCTAssertEqual(managed.recommendation, "")
        XCTAssertEqual(report.summary.checked, 1)
        XCTAssertEqual(report.summary.healthy, 1)
        XCTAssertEqual(report.summary.unmanaged, 0)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.volumes.count, 1)
        XCTAssertEqual(report.volumes[0].manifestStatus, .loaded)
        XCTAssertEqual(report.volumes[0].recordCount, 1)
    }

    func testUnmanagedLinkIsInformational() throws {
        let externalApp = volumeDir.appendingPathComponent("Manual/Manual.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Manual.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        let report = try check(makeChecker())

        let unmanaged = try XCTUnwrap(findings(report, code: .linkUnmanaged).first)
        XCTAssertEqual(unmanaged.status, .healthy)
        XCTAssertEqual(unmanaged.managed, false)
        XCTAssertEqual(report.summary.unmanaged, 1)
        XCTAssertEqual(report.summary.needsAttention, 0)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testLinkMatchingMacBayLayoutWithoutRecordIsHealthy() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Layout.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Layout.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        let report = try check(makeChecker())

        let layout = try XCTUnwrap(findings(report, code: .linkManagedLayout).first)
        XCTAssertEqual(layout.status, .healthy)
        XCTAssertEqual(layout.managed, true)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testBrokenLinkNeedsAttention() throws {
        let missingTarget = volumeDir.appendingPathComponent("MacBay/Applications/Offline.app")
        let link = appsDir.appendingPathComponent("Offline.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)

        let report = try check(makeChecker())

        let broken = try XCTUnwrap(findings(report, code: .linkTargetUnavailable).first)
        XCTAssertEqual(broken.status, .needsAttention)
        XCTAssertEqual(broken.name, "Offline.app")
        XCTAssertEqual(broken.paths.map(standardPath), [standardPath(link.path), standardPath(missingTarget.path)])
        XCTAssertTrue(broken.detail.contains("Target unavailable"))
        XCTAssertFalse(broken.recommendation.isEmpty)
        XCTAssertEqual(report.summary.needsAttention, 1)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testCircularLinkNeedsAttention() throws {
        let loopA = appsDir.appendingPathComponent("LoopA.app")
        let loopB = appsDir.appendingPathComponent("LoopB.app")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.path)
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.path)

        let report = try check(makeChecker())

        let circular = findings(report, code: .linkCircular)
        XCTAssertEqual(circular.count, 2)
        for finding in circular {
            XCTAssertEqual(finding.status, .needsAttention)
            XCTAssertTrue(finding.detail.contains("Circular link detected"))
        }
        XCTAssertEqual(report.exitCode, 1)
    }

    func testRelativeAndChainedLinksResolve() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Target.app")
        try createDirectory(at: externalApp)

        let intermediate = appsDir.appendingPathComponent("LinkB.app")
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: externalApp)

        let relativeLink = appsDir.appendingPathComponent("LinkA.app")
        try FileManager.default.createSymbolicLink(atPath: relativeLink.path, withDestinationPath: "LinkB.app")

        let report = try check(makeChecker())

        let relative = try XCTUnwrap(findings(report, code: .linkManagedLayout).first { $0.name == "LinkA.app" })
        XCTAssertTrue(relative.detail.contains("relative link"))
        XCTAssertTrue(relative.detail.contains("2 hops"))

        let single = try XCTUnwrap(findings(report, code: .linkManagedLayout).first { $0.name == "LinkB.app" })
        XCTAssertFalse(single.detail.contains("hops"))
        XCTAssertEqual(report.exitCode, 0)
    }

    func testUnreadableLinkIsUnverified() throws {
        let ghostTarget = volumeDir.appendingPathComponent("MacBay/Applications/Ghost.app")
        let ghost = appsDir.appendingPathComponent("Ghost.app")
        try FileManager.default.createSymbolicLink(at: ghost, withDestinationURL: ghostTarget)

        let fileManager = MockFileManager(mountedPaths: [volumeDir.path])
        fileManager.unreadableLinkPaths = [ghost.path]

        let report = try check(makeChecker(fileManager: fileManager))

        let unreadable = try XCTUnwrap(findings(report, code: .linkUnreadable).first)
        XCTAssertEqual(unreadable.status, .unableToVerify)
        XCTAssertEqual(unreadable.paths, [ghost.path])
        XCTAssertFalse(unreadable.recommendation.isEmpty)
        XCTAssertEqual(report.summary.unableToVerify, 1)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testUnreadableApplicationDirectoryIsUnverified() throws {
        let fileManager = MockFileManager(mountedPaths: [volumeDir.path])
        fileManager.unreadableDirectoryPaths = [appsDir.path]

        let report = try check(makeChecker(fileManager: fileManager))

        let unreadable = try XCTUnwrap(findings(report, code: .applicationsUnreadable).first)
        XCTAssertEqual(unreadable.status, .unableToVerify)
        XCTAssertEqual(unreadable.paths, [appsDir.path])
        XCTAssertTrue(report.warnings.contains { $0.contains(appsDir.path) })
        XCTAssertEqual(report.exitCode, 1)
    }

    func testCorruptedManifestIsUnverified() throws {
        let manifestURL = MacBayPaths.manifestURL(on: volumeDir)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: manifestURL)

        let report = try check(makeChecker())

        let manifest = try XCTUnwrap(findings(report, code: .manifestUnreadable).first)
        XCTAssertEqual(manifest.status, .unableToVerify)
        XCTAssertEqual(manifest.category, .volume)
        XCTAssertEqual(manifest.paths, [manifestURL.path])
        XCTAssertEqual(report.volumes[0].manifestStatus, .unreadable)
        XCTAssertEqual(report.volumes[0].recordCount, 0)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testUnsupportedManifestVersionIsUnverified() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Future.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Future.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        try saveManifest(
            items: [makeItem(
                name: "Future.app",
                sourcePath: link.standardizedFileURL.path,
                externalPath: externalApp.standardizedFileURL.path
            )],
            version: DockManifest.currentVersion + 98
        )

        let report = try check(makeChecker())

        let version = try XCTUnwrap(findings(report, code: .manifestVersionUnsupported).first)
        XCTAssertEqual(version.status, .unableToVerify)
        XCTAssertEqual(report.volumes[0].manifestStatus, .unsupportedVersion)
        XCTAssertEqual(report.volumes[0].recordCount, 0)
        XCTAssertTrue(findings(report, code: .linkManagedRecord).isEmpty)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testReadOnlyVolumeIsConsulted() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Archive.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Archive.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)

        try saveManifest(items: [makeItem(
            name: "Archive.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let checker = makeChecker(extraDiskInfo: [
            volumeDir.path: makeDiskInfo(mountPoint: volumeDir.path, isWritableVolume: false)
        ])
        let report = try check(checker)

        XCTAssertEqual(report.volumes.count, 1)
        let scope = try XCTUnwrap(report.volumes.first)
        XCTAssertTrue(scope.isReadOnly)
        XCTAssertEqual(findings(report, code: .linkManagedRecord).count, 1)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testRecordedTargetMissingNeedsAttention() throws {
        let link = appsDir.appendingPathComponent("Vanished.app")
        try createDirectory(at: link)
        try saveManifest(items: [makeItem(
            name: "Vanished.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: volumeDir.appendingPathComponent("MacBay/Applications/Vanished.app").path
        )])

        let report = try check(makeChecker())

        let missing = try XCTUnwrap(findings(report, code: .recordTargetMissing).first)
        XCTAssertEqual(missing.status, .needsAttention)
        XCTAssertEqual(missing.category, .record)
        XCTAssertEqual(missing.paths.count, 2)
        XCTAssertTrue(missing.detail.contains("Recorded external copy is missing"))
        XCTAssertTrue(missing.detail.contains("local data is present"))
        XCTAssertNotNil(missing.localSizeBytes)
        XCTAssertNil(missing.externalSizeBytes)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testLocalDataDetectedWhenBothCopiesExist() throws {
        let localApp = appsDir.appendingPathComponent("Regrown.app")
        try createDirectory(at: localApp)
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Regrown.app")
        try createDirectory(at: externalApp)

        try saveManifest(items: [makeItem(
            name: "Regrown.app",
            sourcePath: localApp.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        let localData = try XCTUnwrap(findings(report, code: .localDataDetected).first)
        XCTAssertEqual(localData.status, .needsAttention)
        XCTAssertEqual(localData.category, .record)
        XCTAssertEqual(localData.paths.map(standardPath), [
            standardPath(localApp.path),
            standardPath(externalApp.path)
        ])
        XCTAssertTrue(localData.detail.contains("Local data detected at"))
        XCTAssertTrue(localData.detail.contains("recorded copy exists at"))
        XCTAssertNotNil(localData.localSizeBytes)
        XCTAssertNotNil(localData.externalSizeBytes)
        XCTAssertTrue(localData.recommendation.contains("does not delete, overwrite, or re-move"))
        XCTAssertEqual(report.summary.needsAttention, 1)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testLocalDataDetectionDoesNotClaimRegeneration() throws {
        let localApp = appsDir.appendingPathComponent("Same.app")
        try createDirectory(at: localApp)
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Same.app")
        try createDirectory(at: externalApp)

        try saveManifest(items: [makeItem(
            name: "Same.app",
            sourcePath: localApp.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker())
        let finding = try XCTUnwrap(findings(report, code: .localDataDetected).first)

        let text = (finding.detail + " " + finding.recommendation).lowercased()
        for claim in ["update", "regenerated", "recreated", "identical", "duplicate", "same content"] {
            XCTAssertFalse(text.contains(claim), "Finding must not assert '\(claim)': \(text)")
        }
    }

    func testRecordedSourceMissingNeedsAttention() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Orphan.app")
        try createDirectory(at: externalApp)
        try saveManifest(items: [makeItem(
            name: "Orphan.app",
            sourcePath: appsDir.appendingPathComponent("Orphan.app").standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        let orphan = try XCTUnwrap(findings(report, code: .recordSourceMissing).first)
        XCTAssertEqual(orphan.status, .needsAttention)
        XCTAssertEqual(orphan.category, .record)
        XCTAssertTrue(orphan.detail.contains("Recorded source path is missing"))
        XCTAssertNotNil(orphan.externalSizeBytes)
        XCTAssertNil(orphan.localSizeBytes)
        XCTAssertTrue(orphan.recommendation.contains("does not change records automatically"))
        XCTAssertEqual(report.exitCode, 1)
    }

    func testRecordWithBothPathsMissingIsNotReportedAsDuplication() throws {
        try saveManifest(items: [makeItem(
            name: "Gone.app",
            sourcePath: appsDir.appendingPathComponent("Gone.app").standardizedFileURL.path,
            externalPath: volumeDir.appendingPathComponent("MacBay/Applications/Gone.app").path
        )])

        let report = try check(makeChecker())

        XCTAssertTrue(findings(report, code: .localDataDetected).isEmpty)
        let missing = try XCTUnwrap(findings(report, code: .recordTargetMissing).first)
        XCTAssertTrue(missing.detail.contains("the recorded source path is also missing"))
        XCTAssertNil(missing.localSizeBytes)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testNotesExplainScopeAndUnreadableManifests() throws {
        let manifestURL = MacBayPaths.manifestURL(on: volumeDir)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: manifestURL)

        let report = try check(makeChecker())

        XCTAssertTrue(report.notes.contains { $0.contains("manually relocated items have no MacBay history") })
        XCTAssertTrue(report.notes.contains { $0.contains("were not checked because its manifest could not be read") })
    }

    func testNotesWhenNoVolumesAreConsulted() throws {
        let report = try check(makeChecker(mountedPaths: []))

        XCTAssertEqual(report.notes.count, 1)
        XCTAssertTrue(report.notes[0].contains("No external volumes were consulted"))
    }

    func testDoctorIgnoresConversationHistoryWithMissingAppPaths() throws {
        let history = tempDir.appendingPathComponent(".gemini/antigravity/brain/session/messages/record.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        var entries: [String] = []
        for index in 0..<300 {
            entries.append("/Volumes/NoSuchVolume/DerivedData/deno.app/Contents/\(index)")
        }
        let payload = "{ \"content\": \"" + entries.joined(separator: " ") + "\" }\n"
        try Data(payload.utf8).write(to: history)

        let report = try check(makeChecker())

        XCTAssertTrue(report.findings.filter { $0.category == .externalReference }.isEmpty)
        XCTAssertEqual(report.summary.needsAttention, 0)
        XCTAssertEqual(report.summary.unableToVerify, 0)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testLocalDataCheckSkipsRecordedLinks() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Linked.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)
        try saveManifest(items: [makeItem(
            name: "Linked.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        XCTAssertEqual(findings(report, code: .linkManagedRecord).count, 1)
        XCTAssertTrue(findings(report, code: .localDataDetected).isEmpty)
        XCTAssertTrue(findings(report, code: .recordTargetMissing).isEmpty)
        XCTAssertTrue(findings(report, code: .recordSourceMissing).isEmpty)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testDoctorReportDecodesWithoutNotesField() throws {
        let legacyJSON = """
        {
          "generatedAt": "2026-09-10T12:00:00Z",
          "volumes": [],
          "findings": [],
          "summary": {"checked": 0, "healthy": 0, "unmanaged": 0, "needsAttention": 0, "unableToVerify": 0},
          "warnings": []
        }
        """
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(legacyJSON.utf8))

        XCTAssertTrue(report.notes.isEmpty)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testDoctorFindingDecodesWithoutReferenceLocations() throws {
        let legacyJSON = """
        {
          "code": "link_unmanaged",
          "status": "healthy",
          "category": "application_link",
          "name": "Legacy.app",
          "paths": ["/Applications/Legacy.app"],
          "detail": "No MacBay record for this link",
          "recommendation": ""
        }
        """
        let finding = try JSONDecoder().decode(DoctorFinding.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(finding.referenceLocations)
        XCTAssertEqual(finding.code, .linkUnmanaged)
    }

    func testRecordTargetCheckSkipsRecordedLinks() throws {
        let missingTarget = volumeDir.appendingPathComponent("MacBay/Applications/Offline.app")
        let link = appsDir.appendingPathComponent("Offline.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)
        try saveManifest(items: [makeItem(
            name: "Offline.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: missingTarget.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        XCTAssertEqual(findings(report, code: .linkTargetUnavailable).count, 1)
        XCTAssertTrue(findings(report, code: .recordTargetMissing).isEmpty)
    }

    func testLinkRecordMismatchNeedsAttention() throws {
        let recordedTarget = volumeDir.appendingPathComponent("MacBay/Applications/Aside.app")
        try createDirectory(at: recordedTarget)
        let actualTarget = volumeDir.appendingPathComponent("Manual/Aside.app")
        try createDirectory(at: actualTarget)

        let link = appsDir.appendingPathComponent("Aside.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actualTarget)
        try saveManifest(items: [makeItem(
            name: "Aside.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: recordedTarget.standardizedFileURL.path
        )])

        let report = try check(makeChecker())

        let mismatch = try XCTUnwrap(findings(report, code: .linkRecordMismatch).first)
        XCTAssertEqual(mismatch.status, .needsAttention)
        XCTAssertEqual(mismatch.paths.map(standardPath), [
            standardPath(link.path),
            standardPath(actualTarget.path),
            standardPath(recordedTarget.path)
        ])
        XCTAssertTrue(mismatch.recommendation.contains("does not change links"))
        XCTAssertEqual(report.exitCode, 1)
    }

    func testDeveloperCacheLinkIsClassifiedByLayout() throws {
        let cacheTarget = tempDir.appendingPathComponent(".npm")
        let externalCache = volumeDir.appendingPathComponent("MacBay/Caches/npm")
        try createDirectory(at: externalCache)
        try FileManager.default.createSymbolicLink(at: cacheTarget, withDestinationURL: externalCache)

        let report = try check(
            makeChecker(),
            cacheTargets: [DeveloperCacheTarget(name: "npm cache", path: cacheTarget)]
        )

        let finding = try XCTUnwrap(findings(report, code: .linkManagedLayout).first)
        XCTAssertEqual(finding.name, "npm cache")
        XCTAssertEqual(finding.category, .developerDataLink)
        XCTAssertEqual(finding.status, .healthy)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testBrokenDeveloperCacheLinkIsReported() throws {
        let cacheTarget = tempDir.appendingPathComponent(".npm")
        try FileManager.default.createSymbolicLink(
            at: cacheTarget,
            withDestinationURL: volumeDir.appendingPathComponent("MacBay/Caches/npm")
        )

        let report = try check(
            makeChecker(),
            cacheTargets: [DeveloperCacheTarget(name: "npm cache", path: cacheTarget)]
        )

        let finding = try XCTUnwrap(findings(report, code: .linkTargetUnavailable).first)
        XCTAssertEqual(finding.name, "npm cache")
        XCTAssertEqual(finding.category, .developerDataLink)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testNothingToVerifyReportsEmptyScope() throws {
        let report = try check(makeChecker(mountedPaths: []))

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.volumes.isEmpty)
        XCTAssertEqual(report.summary.checked, 0)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testPlainApplicationDirectoryIsNotReported() throws {
        let plain = appsDir.appendingPathComponent("Plain.app")
        try createDirectory(at: plain)

        let report = try check(makeChecker(mountedPaths: []))

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testDoctorDoesNotModifyFiles() throws {
        let managedTarget = volumeDir.appendingPathComponent("MacBay/Applications/Managed.app")
        try createDirectory(at: managedTarget)
        let managedLink = appsDir.appendingPathComponent("Managed.app")
        try FileManager.default.createSymbolicLink(at: managedLink, withDestinationURL: managedTarget)

        let manualTarget = volumeDir.appendingPathComponent("Manual/Manual.app")
        try createDirectory(at: manualTarget)
        let manualLink = appsDir.appendingPathComponent("Manual.app")
        try FileManager.default.createSymbolicLink(at: manualLink, withDestinationURL: manualTarget)

        let brokenLink = appsDir.appendingPathComponent("Broken.app")
        try FileManager.default.createSymbolicLink(
            at: brokenLink,
            withDestinationURL: volumeDir.appendingPathComponent("MacBay/Applications/Broken.app")
        )

        let plain = appsDir.appendingPathComponent("Plain.app")
        try createDirectory(at: plain)

        try saveManifest(items: [makeItem(
            name: "Managed.app",
            sourcePath: managedLink.standardizedFileURL.path,
            externalPath: managedTarget.standardizedFileURL.path
        )])

        let before = try snapshot(of: tempDir)
        let report = try check(makeChecker())
        let after = try snapshot(of: tempDir)

        XCTAssertEqual(before, after)
        XCTAssertFalse(report.findings.isEmpty)
    }

    func testExplicitVolumePathIsInspected() throws {
        let externalApp = volumeDir.appendingPathComponent("MacBay/Applications/Explicit.app")
        try createDirectory(at: externalApp)
        let link = appsDir.appendingPathComponent("Explicit.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalApp)
        try saveManifest(items: [makeItem(
            name: "Explicit.app",
            sourcePath: link.standardizedFileURL.path,
            externalPath: externalApp.standardizedFileURL.path
        )])

        let report = try check(makeChecker(mountedPaths: []), volumePath: volumeDir.path)

        XCTAssertEqual(report.volumes.count, 1)
        XCTAssertEqual(report.volumes[0].mountPoint, volumeDir.path)
        XCTAssertEqual(findings(report, code: .linkManagedRecord).count, 1)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testInvalidExplicitVolumePathThrows() throws {
        let checker = makeChecker(mountedPaths: [])

        XCTAssertThrowsError(try check(checker, volumePath: tempDir.appendingPathComponent("Missing").path)) { error in
            guard case MacBayError.invalidVolume = error else {
                return XCTFail("Expected invalidVolume, got \(error)")
            }
        }
    }

    func testDefaultVolumeMountedIsHealthy() throws {
        let store = try saveDefaultVolume(path: volumeDir.path, name: "ExternalSSD", uuid: "UUID-SSD")

        let report = try check(makeChecker(configStore: store))

        let finding = try XCTUnwrap(findings(report, code: .defaultVolumeMounted).first)
        XCTAssertEqual(finding.status, .healthy)
        XCTAssertEqual(finding.category, .volume)
        XCTAssertEqual(finding.name, "ExternalSSD")
        XCTAssertEqual(finding.paths, [volumeDir.path])
        XCTAssertEqual(finding.recommendation, "")
        XCTAssertTrue(finding.detail.contains("Default volume is mounted"))
        XCTAssertEqual(report.exitCode, 0)
    }

    func testDefaultVolumeNotMountedNeedsAttention() throws {
        let offline = volumesDir.appendingPathComponent("OfflineSSD")
        let store = try saveDefaultVolume(path: offline.path, name: "OfflineSSD")

        let report = try check(makeChecker(configStore: store))

        let finding = try XCTUnwrap(findings(report, code: .defaultVolumeUnavailable).first)
        XCTAssertEqual(finding.status, .needsAttention)
        XCTAssertEqual(finding.category, .volume)
        XCTAssertEqual(finding.paths, [offline.path])
        XCTAssertEqual(finding.recommendation, "Run 'mb init' to update the default volume.")
        XCTAssertEqual(report.exitCode, 1)
    }

    func testDefaultVolumeIneligibleNeedsAttention() throws {
        let store = try saveDefaultVolume(path: volumeDir.path, name: "ExternalSSD")

        let checker = makeChecker(
            extraDiskInfo: [volumeDir.path: makeDiskInfo(mountPoint: volumeDir.path, isWritableVolume: false)],
            configStore: store
        )
        let report = try check(checker)

        let finding = try XCTUnwrap(findings(report, code: .defaultVolumeIneligible).first)
        XCTAssertEqual(finding.status, .needsAttention)
        XCTAssertEqual(finding.paths, [volumeDir.path])
        XCTAssertTrue(finding.detail.contains("read-only"))
        XCTAssertEqual(report.exitCode, 1)
    }

    func testDefaultVolumeFoundByUUIDAfterMountPathChange() throws {
        let store = try saveDefaultVolume(
            path: volumesDir.appendingPathComponent("ExternalSSD-OLD").path,
            name: "ExternalSSD",
            uuid: "UUID-SSD"
        )
        let mounted = makeDiskInfo(mountPoint: volumeDir.path)
        let info = VolumeDiskInfo(
            mountPoint: mounted.mountPoint,
            isInternal: mounted.isInternal,
            filesystemType: mounted.filesystemType,
            isWritableVolume: mounted.isWritableVolume,
            busProtocol: mounted.busProtocol,
            volumeName: mounted.volumeName,
            totalBytes: mounted.totalBytes,
            availableBytes: mounted.availableBytes,
            volumeUUID: "UUID-SSD"
        )

        let report = try check(makeChecker(extraDiskInfo: [volumeDir.path: info], configStore: store))

        let finding = try XCTUnwrap(findings(report, code: .defaultVolumeMounted).first)
        XCTAssertEqual(finding.status, .healthy)
        XCTAssertTrue(finding.detail.contains("the saved path was"))
        XCTAssertEqual(finding.paths, [volumeDir.path])
        XCTAssertEqual(report.exitCode, 0)
    }

    func testUnreadableConfigIsUnverified() throws {
        let store = makeConfigStore()
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: store.configURL)

        let report = try check(makeChecker(configStore: store))

        let finding = try XCTUnwrap(findings(report, code: .configUnreadable).first)
        XCTAssertEqual(finding.status, .unableToVerify)
        XCTAssertEqual(finding.category, .volume)
        XCTAssertEqual(finding.paths, [store.configURL.path])
        XCTAssertTrue(finding.recommendation.contains("mb init"))
        XCTAssertEqual(report.exitCode, 1)
    }

    func testWithoutSavedDefaultVolumeNoConfigFindingIsAdded() throws {
        let report = try check(makeChecker())

        XCTAssertTrue(findings(report, code: .defaultVolumeMounted).isEmpty)
        XCTAssertTrue(findings(report, code: .defaultVolumeUnavailable).isEmpty)
        XCTAssertTrue(findings(report, code: .defaultVolumeIneligible).isEmpty)
        XCTAssertTrue(findings(report, code: .configUnreadable).isEmpty)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testIncompleteOperationFinding() throws {
        let journal = OperationJournal()
        let record = AdoptOperationRecord(
            id: UUID().uuidString,
            appName: "Orphaned.app",
            sourcePath: appsDir.appendingPathComponent("Orphaned.app").path,
            originalExternalPath: volumeDir.appendingPathComponent("Applications/Orphaned.app").path,
            targetExternalPath: volumeDir.appendingPathComponent("MacBay/Applications/Orphaned.app").path,
            originalLinkTarget: volumeDir.appendingPathComponent("Applications/Orphaned.app").path,
            volumePath: volumeDir.path,
            phase: .appMoved,
            timestamp: macBayTimestamp()
        )
        try journal.save(record, on: volumeDir)

        let report = try check(makeChecker())
        let matched = findings(report, code: .incompleteOperation)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.status, .needsAttention)
        XCTAssertEqual(matched.first?.name, "Orphaned.app")
        XCTAssertTrue(matched.first?.detail.contains("app_moved") == true)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testFixRecreatesMissingSourceLink() throws {
        // record_source_missing: 기록상 링크여야 할 소스가 없고 외장 사본은 존재 → --fix가 링크를 재생성한다.
        let source = tempDir.appendingPathComponent("MovedData")
        let external = volumeDir.appendingPathComponent("MacBay/Data/MovedData")
        try createDirectory(at: external)
        try saveManifest(items: [
            makeItem(name: "MovedData", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let before = try check(makeChecker())
        XCTAssertEqual(findings(before, code: .recordSourceMissing).count, 1)
        XCTAssertEqual(before.autoFixableFindings.count, 1)

        let report = try check(makeChecker(), fix: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.status, .fixed)
        XCTAssertEqual(fix.code, .recordSourceMissing)

        // 재검사 결과에서도 정상으로 전이됐는지 확인한다.
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        XCTAssertEqual(target, external.path)
        XCTAssertTrue(findings(report, code: .recordSourceMissing).isEmpty)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testFixRepointsBrokenLinkToRecordedCopy() throws {
        // link_target_unavailable: 링크가 가리키는 곳이 없고, 기록된 외장 사본은 존재 → --fix가 재설정한다.
        let source = tempDir.appendingPathComponent("Lib")
        let external = volumeDir.appendingPathComponent("MacBay/Data/Lib")
        try createDirectory(at: external)
        try FileManager.default.createSymbolicLink(
            atPath: source.path,
            withDestinationPath: tempDir.appendingPathComponent("gone").path
        )
        try saveManifest(items: [
            makeItem(name: "Lib", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let report = try check(makeChecker(), fix: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.status, .fixed)
        XCTAssertEqual(fix.code, .linkTargetUnavailable)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: source.path),
            external.path
        )
        XCTAssertTrue(findings(report, code: .linkTargetUnavailable).isEmpty)
    }

    func testFixRepointsCircularLink() throws {
        let source = tempDir.appendingPathComponent("Loop")
        let external = volumeDir.appendingPathComponent("MacBay/Data/Loop")
        try createDirectory(at: external)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: source.path)
        try saveManifest(items: [
            makeItem(name: "Loop", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let report = try check(makeChecker(), fix: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.code, .linkCircular)
        XCTAssertEqual(fix.status, .fixed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: source.path),
            external.path
        )
    }

    func testFixSkipsWhenRecordedCopyIsMissing() throws {
        // 외장 사본이 없으면 안전하게 고칠 수 없으므로 스킵한다.
        let source = tempDir.appendingPathComponent("Lib")
        let external = volumeDir.appendingPathComponent("MacBay/Data/Lib")
        try FileManager.default.createSymbolicLink(
            atPath: source.path,
            withDestinationPath: tempDir.appendingPathComponent("gone").path
        )
        try saveManifest(items: [
            makeItem(name: "Lib", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let report = try check(makeChecker(), fix: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.status, .skipped)
        // 링크는 그대로 두고 파인딩도 유지된다.
        XCTAssertEqual(findings(report, code: .linkTargetUnavailable).count, 1)
    }

    func testFixWithoutRecordIsSkipped() throws {
        // 기록 없는 깨진 링크(캐시 대상 등록 경로)는 의도를 알 수 없어 스킵한다.
        let cacheSource = tempDir.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(
            atPath: cacheSource.path,
            withDestinationPath: tempDir.appendingPathComponent("gone").path
        )
        let report = try check(
            makeChecker(),
            cacheTargets: [DeveloperCacheTarget(name: "cache", path: cacheSource)],
            fix: true
        )
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.status, .skipped)
        XCTAssertEqual(fix.code, .linkTargetUnavailable)
    }

    func testFixDryRunPlansWithoutChangingAnything() throws {
        let source = tempDir.appendingPathComponent("MovedData")
        let external = volumeDir.appendingPathComponent("MacBay/Data/MovedData")
        try createDirectory(at: external)
        try saveManifest(items: [
            makeItem(name: "MovedData", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let report = try check(makeChecker(), fix: true, dryRun: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.status, .planned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        // dry-run은 원래 파인딩을 그대로 보고한다.
        XCTAssertEqual(findings(report, code: .recordSourceMissing).count, 1)
    }

    func testFixReportsUnfixableFindingsAsSkipped() throws {
        // localDataDetected 같은 판단이 필요한 파인딩은 자동으로 고치지 않는다.
        let source = tempDir.appendingPathComponent("Conflict")
        let external = volumeDir.appendingPathComponent("MacBay/Data/Conflict")
        try createDirectory(at: external)
        try createDirectory(at: source)
        try saveManifest(items: [
            makeItem(name: "Conflict", sourcePath: source.path, externalPath: external.path, kind: .directory)
        ])

        let report = try check(makeChecker(), fix: true)
        let fix = try XCTUnwrap(report.fixes.first)
        XCTAssertEqual(fix.code, .localDataDetected)
        XCTAssertEqual(fix.status, .skipped)
    }

    private func snapshot(of root: URL) throws -> [String] {
        var entries: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return entries
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            let relativePath = item.path.replacingOccurrences(of: root.path, with: "")
            if values.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                entries.append("\(relativePath)|link|\(destination)")
            } else {
                entries.append("\(relativePath)|file|\(values.fileSize ?? 0)")
            }
        }
        entries.sort()
        return entries
    }
}
