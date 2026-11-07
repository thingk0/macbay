import XCTest
@testable import MacBayKit

final class CachePurgePlanTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var cache: URL!
    private var dataFile: URL!
    private var runner: CachePlanRunner!
    private var manager: FileManager!
    private var service: MacBayService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        home = root.appendingPathComponent("Home")
        cache = home.appendingPathComponent("Library/Application Support/Example/Code Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        dataFile = cache.appendingPathComponent("cache.data")
        try Data("cache".utf8).write(to: dataFile)
        manager = FileManager()
        runner = CachePlanRunner()
        let environment = ["XDG_STATE_HOME": root.appendingPathComponent("state").path]
        service = MacBayService(fileManager: manager, commandRunner: runner,
            historyStore: HistoryStore(fileManager: manager, environment: environment, homeDirectory: home),
            purgeEngine: PurgeEngine(fileManager: manager, commandRunner: runner, homeDirectory: home))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testCleanupPlanIsReadOnlyAndDeletesOnlyConfirmedCacheContents() throws {
        let items = service.scanPurge()
        let plan = try service.planCachePurge(items: items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path))
        let result = try service.executeCachePurge(plan: plan)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(service.history(limit: 1).first?.outcome, .success)
    }
    func testChangedCacheContentsRequireAnotherPreview() throws {
        let plan = try service.planCachePurge(items: service.scanPurge())
        try Data("new!!".utf8).write(to: dataFile, options: .atomic)
        XCTAssertThrowsError(try service.executeCachePurge(plan: plan))
        XCTAssertEqual(try String(contentsOf: dataFile), "new!!")
    }
    func testNewlyRunningAppStopsCleanup() throws {
        let plan = try service.planCachePurge(items: service.scanPurge())
        runner.processes = ["Example"]
        XCTAssertThrowsError(try service.executeCachePurge(plan: plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path))
    }
    func testUnknownAndDuplicateSelectionsNeverDeleteData() throws {
        let database = cache.deletingLastPathComponent().appendingPathComponent("user.sqlite")
        try Data("account".utf8).write(to: database)
        let forged = PurgeItem(appName: "Example", path: database.path, category: .chromiumCache, sizeBytes: 7, isRunning: false)
        XCTAssertThrowsError(try service.planCachePurge(items: [forged]))
        let item = try XCTUnwrap(service.scanPurge().first)
        XCTAssertThrowsError(try service.planCachePurge(items: [item, item]))
        XCTAssertEqual(try String(contentsOf: database), "account")
    }
    func testPartialRemovalIsReportedAndRemainingFilesArePreserved() throws {
        let second = cache.appendingPathComponent("removable.data")
        try Data("other".utf8).write(to: second)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dataFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: dataFile.path) }
        let plan = try service.planCachePurge(items: service.scanPurge())
        let result = try service.executeCachePurge(plan: plan)
        XCTAssertFalse(result.failedItems.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(service.history(limit: 1).first?.outcome, .partial)
    }
}

private final class CachePlanRunner: CommandRunner, @unchecked Sendable {
    var processes: [String] = []
    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        CommandResult(status: 0, standardOutput: executable.contains("ps") ? processes.joined(separator: "\n") : "", standardError: "")
    }
}
