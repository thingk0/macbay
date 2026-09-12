import Foundation
import XCTest
@testable import MacBayKit

final class PurgeTests: XCTestCase {
    private var tempDir: URL!
    private var homeDir: URL!
    private var appSupportDir: URL!
    private var cachesDir: URL!

    override func setUpWithError() throws {
        let baseTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        let canon = (try? baseTemp.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? baseTemp.path
        tempDir = URL(fileURLWithPath: canon)
        homeDir = tempDir.appendingPathComponent("UserHome")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        appSupportDir = homeDir.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        cachesDir = homeDir.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWhitelistedCachesAreDiscovered() throws {
        let slackApp = appSupportDir.appendingPathComponent("Slack")
        let codeCache = slackApp.appendingPathComponent("Code Cache")
        let gpuCache = slackApp.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: codeCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gpuCache, withIntermediateDirectories: true)

        try Data(repeating: 0x41, count: 100).write(to: codeCache.appendingPathComponent("v8.cache"))
        try Data(repeating: 0x42, count: 200).write(to: gpuCache.appendingPathComponent("shader.cache"))

        let engine = PurgeEngine(homeDirectory: homeDir)
        let items = engine.scan()

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.path == codeCache.path && $0.sizeBytes == 100 })
        XCTAssertTrue(items.contains { $0.path == gpuCache.path && $0.sizeBytes == 200 })
    }

    func testCriticalUserFilesAreNeverTargeted() throws {
        let app = appSupportDir.appendingPathComponent("MyCriticalApp")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        // Sensitive user data files and directories
        let dbFile = app.appendingPathComponent("user_data.sqlite")
        let dbWal = app.appendingPathComponent("user_data.sqlite-wal")
        let settingsFile = app.appendingPathComponent("settings.json")
        let indexedDB = app.appendingPathComponent("IndexedDB")
        let cookies = app.appendingPathComponent("Cookies")
        let localStorage = app.appendingPathComponent("Local Storage")

        try FileManager.default.createDirectory(at: indexedDB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localStorage, withIntermediateDirectories: true)
        try Data("sensitive DB".utf8).write(to: dbFile)
        try Data("wal data".utf8).write(to: dbWal)
        try Data("settings".utf8).write(to: settingsFile)
        try Data("cookie data".utf8).write(to: cookies)

        // Only create one legitimate whitelisted cache
        let cacheStorage = app.appendingPathComponent("CacheStorage")
        try FileManager.default.createDirectory(at: cacheStorage, withIntermediateDirectories: true)
        try Data(repeating: 0x99, count: 50).write(to: cacheStorage.appendingPathComponent("cached.res"))

        let engine = PurgeEngine(homeDirectory: homeDir)
        let items = engine.scan()

        // MUST only find CacheStorage, never the user data/DBs
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path, cacheStorage.path)

        // Safety assertion: none of the critical paths are present in scanned paths
        let scannedPaths = items.map(\.path)
        XCTAssertFalse(scannedPaths.contains(dbFile.path))
        XCTAssertFalse(scannedPaths.contains(dbWal.path))
        XCTAssertFalse(scannedPaths.contains(settingsFile.path))
        XCTAssertFalse(scannedPaths.contains(indexedDB.path))
        XCTAssertFalse(scannedPaths.contains(cookies.path))
        XCTAssertFalse(scannedPaths.contains(localStorage.path))
    }

    func testDryRunCalculatesReclaimedBytesWithoutRemovingFiles() throws {
        let app = appSupportDir.appendingPathComponent("TestApp")
        let gpuCache = app.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: gpuCache, withIntermediateDirectories: true)
        let cacheFile = gpuCache.appendingPathComponent("test.bin")
        try Data(repeating: 0x11, count: 300).write(to: cacheFile)

        let engine = PurgeEngine(homeDirectory: homeDir)
        let items = engine.scan()
        let report = try engine.execute(items: items, dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.totalReclaimedBytes, 300)
        XCTAssertEqual(report.purgedItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path), "Dry run must not remove files")
    }

    func testRealExecutionClearsTargetDirectoryContents() throws {
        let app = appSupportDir.appendingPathComponent("TestApp")
        let codeCache = app.appendingPathComponent("Code Cache")
        try FileManager.default.createDirectory(at: codeCache, withIntermediateDirectories: true)
        let cacheFile = codeCache.appendingPathComponent("bytecode.bin")
        try Data(repeating: 0x22, count: 400).write(to: cacheFile)

        let engine = PurgeEngine(homeDirectory: homeDir)
        let items = engine.scan()
        let report = try engine.execute(items: items, dryRun: false)

        XCTAssertFalse(report.dryRun)
        XCTAssertEqual(report.totalReclaimedBytes, 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codeCache.path), "Target directory itself must be preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path), "Files inside target directory must be cleared")
    }

    func testRunningAppIsSkippedUnlessIncludeRunning() throws {
        let app = appSupportDir.appendingPathComponent("RunningApp")
        let gpuCache = app.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: gpuCache, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 500).write(to: gpuCache.appendingPathComponent("data.bin"))

        // Mock command runner simulating RunningApp in ps output
        let runner = MockPsCommandRunner(runningProcessNames: ["RunningApp"])
        let engine = PurgeEngine(commandRunner: runner, homeDirectory: homeDir)
        let items = engine.scan()

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isRunning)

        // 1. Default execution: skips running app
        let defaultReport = try engine.execute(items: items, options: PurgeOptions(includeRunning: false), dryRun: false)
        XCTAssertEqual(defaultReport.purgedItems.count, 0)
        XCTAssertEqual(defaultReport.skippedItems.count, 1)
        XCTAssertEqual(defaultReport.totalReclaimedBytes, 0)

        // 2. Override with includeRunning: true
        let forcedReport = try engine.execute(items: items, options: PurgeOptions(includeRunning: true), dryRun: false)
        XCTAssertEqual(forcedReport.purgedItems.count, 1)
        XCTAssertEqual(forcedReport.skippedItems.count, 0)
        XCTAssertEqual(forcedReport.totalReclaimedBytes, 500)
    }

    func testAppFilterNarrowsTargets() throws {
        let appA = appSupportDir.appendingPathComponent("AlphaApp/GPUCache")
        let appB = appSupportDir.appendingPathComponent("BetaApp/GPUCache")
        try FileManager.default.createDirectory(at: appA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appB, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 50).write(to: appA.appendingPathComponent("a.bin"))
        try Data(repeating: 0x55, count: 50).write(to: appB.appendingPathComponent("b.bin"))

        let engine = PurgeEngine(homeDirectory: homeDir)

        let filterAlpha = PurgeOptions(appFilter: ["alpha"])
        let alphaItems = engine.scan(options: filterAlpha)
        XCTAssertEqual(alphaItems.count, 1)
        XCTAssertEqual(alphaItems.first?.appName, "AlphaApp")

        let filterBeta = PurgeOptions(appFilter: ["beta"])
        let betaItems = engine.scan(options: filterBeta)
        XCTAssertEqual(betaItems.count, 1)
        XCTAssertEqual(betaItems.first?.appName, "BetaApp")
    }

    func testAppGroupingAndSelectionParsing() throws {
        let item1 = PurgeItem(appName: "AppA", path: "/a/1", category: .chromiumCache, sizeBytes: 100, isRunning: false)
        let item2 = PurgeItem(appName: "AppA", path: "/a/2", category: .chromiumCache, sizeBytes: 200, isRunning: false)
        let item3 = PurgeItem(appName: "AppB", path: "/b/1", category: .chromiumCache, sizeBytes: 500, isRunning: false)
        let item4 = PurgeItem(appName: "AppC", path: "/c/1", category: .chromiumCache, sizeBytes: 50, isRunning: false)

        let groups = PurgeAppGroup.group(items: [item1, item2, item3, item4])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].appName, "AppB") // 500 bytes
        XCTAssertEqual(groups[1].appName, "AppA") // 300 bytes
        XCTAssertEqual(groups[2].appName, "AppC") // 50 bytes

        // Selection parser tests
        // 1) All / affirmative keywords
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "1", groupCount: 3), Set([0, 1, 2]))
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "all", groupCount: 3), Set([0, 1, 2]))
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "y", groupCount: 3), Set([0, 1, 2]))
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "yes", groupCount: 3), Set([0, 1, 2]))

        // 2) Single choice: Option 2 is group index 0 (AppB)
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "2", groupCount: 3), Set([0]))

        // 3) Multi choice: Option 2 and 4 (indices 0 and 2)
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "2, 4", groupCount: 3), Set([0, 2]))
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "2,4", groupCount: 3), Set([0, 2]))
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "2 4", groupCount: 3), Set([0, 2]))

        // 4) Range: Option 2-4
        XCTAssertEqual(PurgeAppGroup.parseSelection(input: "2-4", groupCount: 3), Set([0, 1, 2]))

        // 5) Cancellation and invalid inputs
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "q", groupCount: 3))
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "n", groupCount: 3))
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "no", groupCount: 3))
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "", groupCount: 3))
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "5", groupCount: 3)) // out of bounds
        XCTAssertNil(PurgeAppGroup.parseSelection(input: "abc", groupCount: 3))
    }

    func testInteractivePreviewFormatting() throws {
        let item1 = PurgeItem(appName: "AppA", path: "/Library/Application Support/AppA/Code Cache", category: .chromiumCache, sizeBytes: 1000, isRunning: false)
        let item2 = PurgeItem(appName: "RunningApp", path: "/Library/Application Support/RunningApp/GPUCache", category: .chromiumCache, sizeBytes: 5000, isRunning: true)

        let groups = PurgeAppGroup.group(items: [item1])
        let formatter = OutputFormatter(useColor: false)
        let preview = formatter.formatPurgeInteractivePreview(groups: groups, skippedItems: [item2], totalEligibleBytes: 1000)

        XCTAssertTrue(preview.contains("MacBay cache purge"))
        XCTAssertTrue(preview.contains("1) [All] Purge all targets"))
        XCTAssertTrue(preview.contains("2) AppA"))
        XCTAssertTrue(preview.contains("Code Cache"))
        XCTAssertTrue(preview.contains("Skipped items (running)"))
        XCTAssertTrue(preview.contains("RunningApp"))
    }

    func testHonestAccountingMeasuresActualDeletedBytes() throws {
        let app = appSupportDir.appendingPathComponent("HonestApp")
        let codeCache = app.appendingPathComponent("Code Cache")
        try FileManager.default.createDirectory(at: codeCache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: codeCache.appendingPathComponent("v8_1.bin"))

        let engine = PurgeEngine(homeDirectory: homeDir)
        let scanned = engine.scan()
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.sizeBytes, 100)

        // Add more files after scan
        try Data(repeating: 0x42, count: 200).write(to: codeCache.appendingPathComponent("v8_2.bin"))

        let report = try engine.execute(items: scanned, dryRun: false)
        XCTAssertEqual(report.purgedItems.count, 1)
        XCTAssertEqual(report.totalReclaimedBytes, 300, "Measured reclaim should reflect actual removed bytes")
        XCTAssertEqual(report.purgedItems.first?.sizeBytes, 300)
    }

    func testBackwardCompatibleReportDecoding() throws {
        let legacyJSON = """
        {
            "generatedAt": "2026-09-01T00:00:00Z",
            "dryRun": false,
            "purgedItems": [],
            "totalReclaimedBytes": 0,
            "messages": ["Purge completed successfully"]
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let report = try JSONDecoder().decode(PurgeReport.self, from: data)
        XCTAssertEqual(report.failedItems, [])
        XCTAssertEqual(report.skippedItems, [])
        XCTAssertEqual(report.messages, ["Purge completed successfully"])
    }

    func testRoundTripReportEncodingPreservesFailedItems() throws {
        let failure = PurgeFailure(appName: "TestApp", path: "/tmp/failed", reason: "Permission denied", unreclaimedBytes: 500)
        let report = PurgeReport(
            dryRun: false,
            purgedItems: [],
            skippedItems: [],
            failedItems: [failure],
            totalReclaimedBytes: 0,
            messages: ["Errors encountered"]
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PurgeReport.self, from: data)
        XCTAssertEqual(decoded.failedItems, [failure])
    }
}

private final class MockPsCommandRunner: CommandRunner, @unchecked Sendable {
    let runningProcessNames: [String]

    init(runningProcessNames: [String]) {
        self.runningProcessNames = runningProcessNames
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        if executable.contains("ps") {
            let output = runningProcessNames.joined(separator: "\n")
            return CommandResult(status: 0, standardOutput: output, standardError: "")
        }
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}
