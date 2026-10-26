import Foundation
import XCTest
@testable import MacBayKit

final class RepairBackupUseCaseTests: XCTestCase {
    private var tempDir: URL!
    private var volumeURL: URL!
    private var backupsRoot: URL!
    private var operationsRoot: URL!
    private var useCase: RepairBackupUseCase!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("MacBayRepairBackupTests-\(UUID().uuidString)", isDirectory: true)
        volumeURL = tempDir.appendingPathComponent("ExternalSSD", isDirectory: true)
        backupsRoot = volumeURL.appendingPathComponent("MacBay/Backups", isDirectory: true)
        operationsRoot = volumeURL.appendingPathComponent("MacBay/.operations", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: operationsRoot, withIntermediateDirectories: true)
        useCase = RepairBackupUseCase(operationLock: NoOpVolumeOperationLock())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @discardableResult
    private func makeBackup(
        id: String = UUID().uuidString,
        appName: String = "Kiro CLI.app",
        version: String? = "1.1.0",
        build: String? = "110",
        payloadBytes: Int = 2048
    ) throws -> URL {
        let appURL = backupsRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var entries = [
            "<key>CFBundleExecutable</key><string>App</string>",
            "<key>CFBundleIdentifier</key><string>com.example.backup</string>"
        ]
        if let version {
            entries.append("<key>CFBundleShortVersionString</key><string>\(version)</string>")
        }
        if let build {
            entries.append("<key>CFBundleVersion</key><string>\(build)</string>")
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entries.joined(separator: "\n"))
        </dict>
        </plist>
        """
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: payloadBytes).write(to: contentsURL.appendingPathComponent("Payload"))
        return appURL
    }

    @discardableResult
    private func writeJournal(name: String, contents: String) throws -> URL {
        let url = operationsRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func backupPath(_ appURL: URL) -> String {
        appURL.standardizedFileURL.path
    }

    private func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func journalContents(backupPath: String, appName: String = "Kiro CLI.app") -> String {
        """
        {
          "schemaVersion": 1,
          "id": "op-1",
          "appName": "\(appName)",
          "backupPath": "\(backupPath)"
        }
        """
    }

    func testInventoryListsUnreferencedBackupMetadata() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let appURL = try makeBackup(id: id, appName: "Kiro CLI.app", version: "1.1.0", build: "110")

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.summary.count, 1)
        XCTAssertEqual(inventory.summary.referencedCount, 0)
        XCTAssertEqual(inventory.summary.unverifiableCount, 0)
        XCTAssertEqual(inventory.backups.count, 1)

        let entry = try XCTUnwrap(inventory.backups.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.appName, "Kiro CLI.app")
        XCTAssertEqual(resolvedPath(entry.path), resolvedPath(appURL))
        XCTAssertEqual(entry.version, "1.1.0")
        XCTAssertEqual(entry.buildNumber, "110")
        XCTAssertNotNil(entry.savedAt)
        XCTAssertGreaterThan(entry.sizeBytes ?? 0, 0)
        XCTAssertEqual(entry.state, .unreferenced)
        XCTAssertNil(entry.referencedBy)
        XCTAssertNil(entry.reason)
        XCTAssertTrue(inventory.notes.contains { $0.contains("logical") })
    }

    func testRepairJournalReferenceProtectsBackup() throws {
        let appURL = try makeBackup()
        let journal = try writeJournal(
            name: "repair-Kiro CLI.app.json",
            contents: journalContents(backupPath: backupPath(appURL))
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")
        let entry = try XCTUnwrap(inventory.backups.first)

        XCTAssertEqual(entry.state, .referenced)
        XCTAssertEqual(entry.referencedBy.map { resolvedPath($0) }, resolvedPath(journal))
        XCTAssertEqual(inventory.summary.referencedCount, 1)
    }

    func testJournalReferenceByOperationIDSurvivesRenamedMountPath() throws {
        let id = "22222222-2222-2222-2222-222222222222"
        _ = try makeBackup(id: id)
        try writeJournal(
            name: "repair-renamed.json",
            contents: """
            {"backupPath": "/Volumes/OldName/MacBay/Backups/\(id)/Kiro CLI.app"}
            """
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .referenced)
    }

    func testMalformedJournalContainingBackupPathStillProtectsBackup() throws {
        let appURL = try makeBackup()
        try writeJournal(
            name: "repair-broken.json",
            contents: "{\"backupPath\": \"\(backupPath(appURL))\""
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .referenced)
    }

    func testUnreadableJournalMakesBackupUnverifiable() throws {
        _ = try makeBackup()
        let target = tempDir.appendingPathComponent("unreadable-journal-target")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: operationsRoot.appendingPathComponent("repair-link.json"),
            withDestinationURL: target
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .unverifiable)
        XCTAssertTrue(inventory.backups.first?.reason?.contains("reference") == true)
        XCTAssertTrue(inventory.warnings.contains { $0.contains("operation journals could not be read") })
    }

    func testSymlinkedOperationDirectoryIsNotFollowed() throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        let outsideApp = outside.appendingPathComponent("Kiro CLI.app", isDirectory: true)
        let contents = outsideApp.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32).write(to: contents.appendingPathComponent("Payload"))
        let id = "33333333-3333-3333-3333-333333333333"
        try FileManager.default.createSymbolicLink(
            at: backupsRoot.appendingPathComponent(id),
            withDestinationURL: outside
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")
        let entry = try XCTUnwrap(inventory.backups.first)

        XCTAssertEqual(entry.state, .unverifiable)
        XCTAssertTrue(entry.reason?.contains("symbolic link") == true)
        XCTAssertNil(entry.sizeBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideApp.path))
    }

    func testSymlinkedBackupBundleIsNotFollowed() throws {
        let outside = tempDir.appendingPathComponent("outside-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let id = "44444444-4444-4444-4444-444444444444"
        let operationDirectory = backupsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: operationDirectory.appendingPathComponent("Linked.app"),
            withDestinationURL: outside
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .unverifiable)
        XCTAssertTrue(inventory.backups.first?.reason?.contains("symbolic link") == true)
    }

    func testUnrecognizedLayoutIsProtected() throws {
        let id = "55555555-5555-5555-5555-555555555555"
        let operationDirectory = backupsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: operationDirectory.appendingPathComponent("notes.txt"))

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")
        let entry = try XCTUnwrap(inventory.backups.first)

        XCTAssertEqual(entry.state, .unverifiable)
        XCTAssertTrue(entry.reason?.contains("Unrecognized backup layout") == true)
    }

    func testDSStoreInBackupDirectoryIsIgnored() throws {
        let appURL = try makeBackup()
        try Data(repeating: 0, count: 16).write(
            to: appURL.deletingLastPathComponent().appendingPathComponent(".DS_Store")
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .unreferenced)
    }

    func testDSStoreInOperationsDirectoryDoesNotProtectBackups() throws {
        _ = try makeBackup()
        try Data(repeating: 0, count: 16).write(
            to: operationsRoot.appendingPathComponent(".DS_Store")
        )

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .unreferenced)
    }

    func testMalformedJournalWithoutReferenceProtectsBackup() throws {
        _ = try makeBackup()
        try writeJournal(name: "repair-invalid.json", contents: "{not valid json")

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertEqual(inventory.backups.first?.state, .unverifiable)
        XCTAssertTrue(inventory.warnings.contains { $0.contains("could not be read or parsed") })
    }

    func testSymlinkedBackupsRootIsNotFollowed() throws {
        let outside = tempDir.appendingPathComponent("outside-backups", isDirectory: true)
        let outsideApp = outside.appendingPathComponent("Outside.app", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideApp, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: backupsRoot)
        try FileManager.default.createSymbolicLink(at: backupsRoot, withDestinationURL: outside)

        let inventory = try useCase.inventory(on: volumeURL, volumeName: "ExternalSSD")

        XCTAssertTrue(inventory.backups.isEmpty)
        XCTAssertTrue(inventory.warnings.contains { $0.contains("symbolic link") })
    }

    func testPlanSelectsUnreferencedAndRefusesProtectedBackups() throws {
        let unreferenced = try makeBackup(appName: "Unreferenced.app")
        let referenced = try makeBackup(appName: "Referenced.app")
        try writeJournal(
            name: "repair-referenced.json",
            contents: journalContents(backupPath: backupPath(referenced), appName: "Referenced.app")
        )
        let unreferencedID = URL(fileURLWithPath: unreferenced.path).deletingLastPathComponent().lastPathComponent
        let referencedID = URL(fileURLWithPath: referenced.path).deletingLastPathComponent().lastPathComponent

        let plan = try useCase.planRemoval(
            ids: [unreferencedID, referencedID, "missing-id"],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )

        XCTAssertEqual(plan.selected.map(\.id), [unreferencedID])
        XCTAssertEqual(plan.refused.count, 2)
        XCTAssertTrue(plan.refused.contains { $0.id == referencedID && $0.reason.contains("Referenced by") })
        XCTAssertTrue(plan.refused.contains { $0.id == "missing-id" })
        XCTAssertGreaterThan(plan.totalBytes, 0)
        XCTAssertEqual(plan.exitCode, 1)
    }

    func testPlanResolvesUniquePrefixAndRejectsAmbiguousPrefix() throws {
        let firstID = "abcdef12-aaaa-1111-1111-111111111111"
        let secondID = "abcdef12-bbbb-2222-2222-222222222222"
        let first = try makeBackup(id: firstID, appName: "First.app")
        let second = try makeBackup(id: secondID, appName: "Second.app")

        let ambiguous = try useCase.planRemoval(
            ids: ["abcdef12"],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )
        XCTAssertTrue(ambiguous.selected.isEmpty)
        XCTAssertTrue(ambiguous.refused.first?.reason.contains("matches 2 backups") == true)

        let unique = try useCase.planRemoval(
            ids: ["abcdef12-a"],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )
        XCTAssertEqual(unique.selected.map { resolvedPath($0.path) }, [resolvedPath(first)])
        XCTAssertTrue(unique.refused.isEmpty)

        let exact = try useCase.planRemoval(
            ids: [secondID],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )
        XCTAssertEqual(exact.selected.map { resolvedPath($0.path) }, [resolvedPath(second)])
    }

    func testPlanRejectsPathsAndEmptyIDs() throws {
        _ = try makeBackup()

        let plan = try useCase.planRemoval(
            ids: ["/tmp/evil", "", "  "],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )

        XCTAssertTrue(plan.selected.isEmpty)
        XCTAssertEqual(plan.refused.count, 2)
        XCTAssertTrue(plan.refused.contains { $0.reason.contains("not paths") })
        XCTAssertTrue(plan.refused.contains { $0.reason.contains("empty") })
    }

    func testExecuteRemovesUnreferencedBackupAndOperationDirectory() throws {
        let appURL = try makeBackup()
        let id = URL(fileURLWithPath: appURL.path).deletingLastPathComponent().lastPathComponent
        let operationDirectory = backupsRoot.appendingPathComponent(id)
        let plan = try useCase.planRemoval(ids: [id], on: volumeURL, volumeName: "ExternalSSD")

        let result = try useCase.execute(plan: plan)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertEqual(result.removed.first?.id, id)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationDirectory.path))
    }

    func testExecuteRefusesBackupReferencedAfterPreview() throws {
        let appURL = try makeBackup()
        let id = URL(fileURLWithPath: appURL.path).deletingLastPathComponent().lastPathComponent
        let plan = try useCase.planRemoval(ids: [id], on: volumeURL, volumeName: "ExternalSSD")
        XCTAssertEqual(plan.selected.count, 1)

        try writeJournal(
            name: "repair-new.json",
            contents: journalContents(backupPath: backupPath(appURL))
        )

        let result = try useCase.execute(plan: plan)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.failed.first?.reason.contains("now referenced") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    func testExecuteRefusesBackupChangedAfterPreview() throws {
        let appURL = try makeBackup()
        let id = URL(fileURLWithPath: appURL.path).deletingLastPathComponent().lastPathComponent
        let plan = try useCase.planRemoval(ids: [id], on: volumeURL, volumeName: "ExternalSSD")

        try Data(repeating: 1, count: 1024).write(
            to: appURL.appendingPathComponent("Contents/ExtraPayload")
        )

        let result = try useCase.execute(plan: plan)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(result.failed.first?.reason.contains("changed since the preview") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    func testExecuteReportsPartialFailure() throws {
        let first = try makeBackup(id: "66666666-6666-6666-6666-666666666666", appName: "First.app")
        _ = try makeBackup(id: "77777777-7777-7777-7777-777777777777", appName: "Second.app")
        let failing = FailingRemoveFileSystem(
            base: DarwinRepairBackupFileSystem(),
            failingPath: first.standardizedFileURL.path
        )
        let failingUseCase = RepairBackupUseCase(
            fileSystem: failing,
            operationLock: NoOpVolumeOperationLock()
        )
        let plan = try failingUseCase.planRemoval(
            ids: ["66666666", "77777777"],
            on: volumeURL,
            volumeName: "ExternalSSD"
        )

        let result = try failingUseCase.execute(plan: plan)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.failed.first?.id, "66666666-6666-6666-6666-666666666666")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testMissingBackupsRootIsAnEmptyInventory() throws {
        let emptyVolume = tempDir.appendingPathComponent("EmptyVolume", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyVolume, withIntermediateDirectories: true)

        let inventory = try useCase.inventory(on: emptyVolume, volumeName: "EmptyVolume")

        XCTAssertTrue(inventory.backups.isEmpty)
        XCTAssertEqual(inventory.summary.count, 0)
        XCTAssertEqual(inventory.summary.totalSizeBytes, 0)
        XCTAssertTrue(inventory.notes.contains { $0.contains("No repair backups") })
    }
}

private struct FailingRemoveFileSystem: RepairBackupFileSystem, @unchecked Sendable {
    let base: DarwinRepairBackupFileSystem
    let failingPath: String

    func kind(of url: URL) -> RepairBackupFileKind {
        base.kind(of: url)
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        try base.directoryEntries(at: url)
    }

    func size(of url: URL) throws -> UInt64 {
        try base.size(of: url)
    }

    func bundleMetadata(at url: URL) -> RepairBackupBundleMetadata {
        base.bundleMetadata(at: url)
    }

    func creationDate(of url: URL) -> Date? {
        base.creationDate(of: url)
    }

    func removeItem(at url: URL) throws {
        guard url.standardizedFileURL.path != failingPath else {
            throw NSError(
                domain: "RepairBackupUseCaseTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "simulated removal failure"]
            )
        }
        try base.removeItem(at: url)
    }

    func isDirectoryEmpty(at url: URL) throws -> Bool {
        try base.isDirectoryEmpty(at: url)
    }

    func availableBytes(on volume: URL) throws -> UInt64 {
        try base.availableBytes(on: volume)
    }

    func journalFiles(on volume: URL) -> RepairBackupJournalScan {
        base.journalFiles(on: volume)
    }
}
