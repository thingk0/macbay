import Foundation
import XCTest
@testable import MacBayKit

final class PurgeSafetyTests: XCTestCase {
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

    func testSymlinkedCacheDirectoryIsRejectedDuringScan() throws {
        let preciousDir = tempDir.appendingPathComponent("Precious")
        try FileManager.default.createDirectory(at: preciousDir, withIntermediateDirectories: true)
        let preciousFile = preciousDir.appendingPathComponent("important.txt")
        try "precious data".data(using: .utf8)?.write(to: preciousFile)

        let evilAppDir = appSupportDir.appendingPathComponent("EvilApp")
        try FileManager.default.createDirectory(at: evilAppDir, withIntermediateDirectories: true)

        let symlinkedCache = evilAppDir.appendingPathComponent("Code Cache")
        try FileManager.default.createSymbolicLink(at: symlinkedCache, withDestinationURL: preciousDir)

        let engine = PurgeEngine(homeDirectory: homeDir)
        let scanned = engine.scan()

        XCTAssertFalse(scanned.contains { $0.path == symlinkedCache.path }, "Symlinked cache directory must be excluded from scan")

        let report = try engine.execute(items: scanned, dryRun: false)
        XCTAssertEqual(report.purgedItems.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preciousFile.path), "Precious file must not be removed")
    }

    func testSymlinkedIntermediateDirectoryIsNotRecursedInto() throws {
        let preciousDir = tempDir.appendingPathComponent("Precious2")
        try FileManager.default.createDirectory(at: preciousDir, withIntermediateDirectories: true)
        let codeCache = preciousDir.appendingPathComponent("Code Cache")
        try FileManager.default.createDirectory(at: codeCache, withIntermediateDirectories: true)
        try "data".data(using: .utf8)?.write(to: codeCache.appendingPathComponent("data.bin"))

        let symlinkedApp = appSupportDir.appendingPathComponent("SymlinkedApp")
        try FileManager.default.createSymbolicLink(at: symlinkedApp, withDestinationURL: preciousDir)

        let engine = PurgeEngine(homeDirectory: homeDir)
        let scanned = engine.scan()

        XCTAssertFalse(scanned.contains { $0.path.contains("SymlinkedApp") }, "Symlinked intermediate app directories must not be traversed")
    }

    func testIsContainedInHome() throws {
        XCTAssertFalse(PurgeSafety.isContainedInHome(URL(fileURLWithPath: "/"), homeDirectory: homeDir))
        XCTAssertFalse(PurgeSafety.isContainedInHome(URL(fileURLWithPath: "/tmp/foo"), homeDirectory: homeDir))
        XCTAssertTrue(PurgeSafety.isContainedInHome(homeDir, homeDirectory: homeDir))
        XCTAssertTrue(PurgeSafety.isContainedInHome(appSupportDir.appendingPathComponent("App"), homeDirectory: homeDir))
    }

    func testScanIsCappedAtMaxEntriesPerDirectory() throws {
        let app = appSupportDir.appendingPathComponent("BigApp")
        for index in 0..<4100 {
            let dir = app.appendingPathComponent(String(format: "d%05d", index))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let early = app.appendingPathComponent(String(format: "d%05d", 0)).appendingPathComponent("GPUCache")
        let late = app.appendingPathComponent(String(format: "d%05d", 4099)).appendingPathComponent("GPUCache")
        for dir in [early, late] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 10).write(to: dir.appendingPathComponent("c.bin"))
        }

        let items = PurgeEngine(homeDirectory: homeDir).scan()
        XCTAssertTrue(items.contains { $0.path == early.path })
        XCTAssertFalse(items.contains { $0.path == late.path }, "entries past the cap must not be scanned")
    }

    func testExecuteTimeRejectsHostileAncestorPaths() throws {
        let desktop = homeDir.appendingPathComponent("Desktop")
        let desktopGPUCache = desktop.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: desktopGPUCache, withIntermediateDirectories: true)
        let payload = desktopGPUCache.appendingPathComponent("payload.txt")
        try "important user data".data(using: .utf8)?.write(to: payload)

        let hostileItem = PurgeItem(
            appName: "FakeGPUCache",
            path: desktopGPUCache.path,
            category: .chromiumCache,
            sizeBytes: 100,
            isRunning: false
        )

        let engine = PurgeEngine(homeDirectory: homeDir)
        let report = try engine.execute(items: [hostileItem], dryRun: false)

        XCTAssertEqual(report.purgedItems.count, 0)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertEqual(report.failedItems.first?.reason, PurgeSafety.Rejection.notWhitelisted.reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path), "Desktop files must not be touched")
    }

    func testExecuteUnreadableDirectoryReportsFailureNotSuccess() throws {
        // Skip if running as root
        guard geteuid() != 0 else {
            throw XCTSkip("Permissions check does not apply to root")
        }

        let app = appSupportDir.appendingPathComponent("UnreadableApp")
        let cache = app.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("data.bin")
        try "some data".data(using: .utf8)?.write(to: file)

        // Make directory unreadable (chmod 000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cache.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
        }

        let item = PurgeItem(appName: "UnreadableApp", path: cache.path, category: .chromiumCache, sizeBytes: 9, isRunning: false)
        let engine = PurgeEngine(homeDirectory: homeDir)
        let report = try engine.execute(items: [item], dryRun: false)

        // Must report as failed, NOT purged with 0 bytes!
        XCTAssertEqual(report.purgedItems.count, 0)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertTrue(report.failedItems.first?.reason.contains("Unable to list directory") ?? false)
    }

    func testExecuteTimeRevalidationRejectsHostileItems() throws {
        let appDir = appSupportDir.appendingPathComponent("SafeApp")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let cookiesFile = appDir.appendingPathComponent("Cookies")
        try "cookie data".data(using: .utf8)?.write(to: cookiesFile)

        let hostileItems = [
            PurgeItem(appName: "Root", path: "/", category: .chromiumCache, sizeBytes: 1000, isRunning: false),
            PurgeItem(appName: "SafeApp", path: cookiesFile.path, category: .chromiumCache, sizeBytes: 11, isRunning: false)
        ]

        let engine = PurgeEngine(homeDirectory: homeDir)
        let report = try engine.execute(items: hostileItems, dryRun: false)

        XCTAssertEqual(report.purgedItems.count, 0)
        XCTAssertEqual(report.failedItems.count, 2)
        XCTAssertEqual(report.totalReclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookiesFile.path), "Cookies file must remain untouched")
    }

    func testExecuteTimeSymlinkSwapIsRejected() throws {
        let appDir = appSupportDir.appendingPathComponent("SwapApp")
        let gpuCache = appDir.appendingPathComponent("GPUCache")
        try FileManager.default.createDirectory(at: gpuCache, withIntermediateDirectories: true)
        try "shader data".data(using: .utf8)?.write(to: gpuCache.appendingPathComponent("shader.bin"))

        let engine = PurgeEngine(homeDirectory: homeDir)
        let scanned = engine.scan()
        XCTAssertEqual(scanned.count, 1)

        let otherTarget = tempDir.appendingPathComponent("OtherTarget")
        try FileManager.default.createDirectory(at: otherTarget, withIntermediateDirectories: true)
        let otherFile = otherTarget.appendingPathComponent("survivor.txt")
        try "survive".data(using: .utf8)?.write(to: otherFile)

        // Swap real directory with a symlink before execute
        try FileManager.default.removeItem(at: gpuCache)
        try FileManager.default.createSymbolicLink(at: gpuCache, withDestinationURL: otherTarget)

        let report = try engine.execute(items: scanned, dryRun: false)
        XCTAssertEqual(report.purgedItems.count, 0)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertEqual(report.failedItems.first?.reason, PurgeSafety.Rejection.symbolicLink.reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path), "Target of swapped symlink must survive")
    }
}
