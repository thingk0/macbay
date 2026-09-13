import Foundation
import XCTest
@testable import MacBayKit

final class TeardownManagerTests: XCTestCase {
    private var tempDir: URL!
    private var homeBase: URL!
    private var fakeHome: URL!
    private var volumeDir: URL!
    private var configHome: URL!
    private var externalDiskInfo: VolumeDiskInfo!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeardownManagerTests-\(UUID().uuidString)")
        volumeDir = tempDir.appendingPathComponent("ExtDrive")
        fakeHome = tempDir.appendingPathComponent("UserHome")
        configHome = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        // move()는 실제 홈을 검사하므로 소스는 실제 홈 아래에 만든다.
        homeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacBayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: homeBase, withIntermediateDirectories: true)

        externalDiskInfo = VolumeDiskInfo(
            mountPoint: volumeDir.path,
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: "ExtDrive",
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000,
            volumeUUID: "UUID-EXT"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: homeBase)
        try super.tearDownWithError()
    }

    private func makeEnvironment(
        cacheTargets: [DeveloperCacheTarget],
        mountedPaths: [String]? = nil
    ) -> (manager: TeardownManager, mover: DirectoryMoveManager, config: ConfigStore) {
        let runner = TestBundleCommandRunner(entitlementsXml: "")
        let fileManager = MockFileManager(mountedPaths: mountedPaths ?? ["/", volumeDir.path])
        let provider = MockDiskInfoProvider([
            "/": VolumeDiskInfo(
                mountPoint: "/",
                isInternal: true,
                filesystemType: "apfs",
                isWritableVolume: true,
                busProtocol: "Apple Fabric",
                volumeName: "Macintosh HD",
                totalBytes: 1_000_000_000_000,
                availableBytes: 500_000_000_000,
                volumeUUID: "UUID-INT"
            ),
            volumeDir.path: externalDiskInfo
        ])
        let volumeManager = VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: provider,
            volumeMountPrefix: tempDir.path
        )
        let configStore = ConfigStore(
            fileManager: fileManager,
            environment: ["XDG_CONFIG_HOME": configHome.path],
            homeDirectory: fakeHome
        )
        let cacheManager = CacheManager(
            fileManager: fileManager,
            commandRunner: runner,
            homeDirectory: fakeHome
        )
        let manager = TeardownManager(
            fileManager: fileManager,
            commandRunner: runner,
            volumeManager: volumeManager,
            configStore: configStore,
            cacheManager: cacheManager,
            developerCacheTargets: cacheTargets
        )
        let mover = DirectoryMoveManager(
            fileManager: fileManager,
            commandRunner: runner,
            volumeManager: volumeManager
        )
        return (manager, mover, configStore)
    }

    private func makeCacheTargets() -> [DeveloperCacheTarget] {
        [DeveloperCacheTarget(name: "npm cache", path: fakeHome.appendingPathComponent(".npm"))]
    }

    func testTeardownRestoresMovedDirectoryAndResetsConfiguration() throws {
        let (manager, mover, configStore) = makeEnvironment(cacheTargets: makeCacheTargets())

        // 상태 준비: 디렉터리 하나를 move하고, 캐시 링크와 설정을 만든다.
        let source = homeBase.appendingPathComponent("Games")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Sub"),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: source.appendingPathComponent("Sub/file.txt"))
        _ = try mover.move(path: source.path, on: volumeDir, dryRun: false)

        let cacheTarget = MacBayPaths.cachesRoot(on: volumeDir).appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: cacheTarget, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: cacheTarget.appendingPathComponent("blob"))
        let cacheLink = fakeHome.appendingPathComponent(".npm")
        try FileManager.default.createSymbolicLink(atPath: cacheLink.path, withDestinationPath: cacheTarget.path)

        let zshrc = fakeHome.appendingPathComponent(".zshrc")
        try "alias ll='ls -l'\n# >>> macbay cache >>>\nexport npm_config_cache='/x'\n# <<< macbay cache <<<\n".write(
            to: zshrc, atomically: true, encoding: .utf8
        )
        try configStore.save(MacBayConfig(
            version: MacBayConfig.currentVersion,
            defaultVolume: DefaultVolume(
                path: volumeDir.path, name: "ExtDrive", uuid: "UUID-EXT", savedAt: "2026-09-13T00:00:00Z"
            )
        ))

        let report = try manager.execute(volumePath: nil, dryRun: false)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.restored.count, 1)
        XCTAssertEqual(report.unlinkedCaches.count, 1)
        XCTAssertTrue(report.cacheConfigurationReset)
        XCTAssertTrue(report.defaultVolumeRemoved)

        // 디렉터리 복원
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Sub/file.txt").path
        ))
        XCTAssertTrue(try ManifestStore().load(on: volumeDir).items.isEmpty)

        // 캐시 링크는 빈 디렉터리로 교체하고 외장 사본은 보존한다.
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: cacheLink.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheLink.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheTarget.appendingPathComponent("blob").path))

        // zshrc 블록 제거, 기본 볼륨 삭제
        let zshrcAfter = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(zshrcAfter.contains("alias ll='ls -l'"))
        XCTAssertFalse(zshrcAfter.contains("macbay cache"))
        XCTAssertNil(try configStore.load().defaultVolume)

        // MacBay 외장 루트는 보존하고 notes에 안내를 남긴다.
        XCTAssertTrue(report.notes.contains { $0.contains("MacBay data remains") })
    }

    func testTeardownDryRunChangesNothing() throws {
        let (manager, mover, configStore) = makeEnvironment(cacheTargets: makeCacheTargets())

        let source = homeBase.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try mover.move(path: source.path, on: volumeDir, dryRun: false)

        let zshrc = fakeHome.appendingPathComponent(".zshrc")
        try "# >>> macbay cache >>>\nexport npm_config_cache='/x'\n# <<< macbay cache <<<\n".write(
            to: zshrc, atomically: true, encoding: .utf8
        )
        try configStore.save(MacBayConfig(
            version: MacBayConfig.currentVersion,
            defaultVolume: DefaultVolume(
                path: volumeDir.path, name: "ExtDrive", uuid: "UUID-EXT", savedAt: "2026-09-13T00:00:00Z"
            )
        ))

        let report = try manager.execute(volumePath: nil, dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains("macbay cache"))
        XCTAssertNotNil(try configStore.load().defaultVolume)
        XCTAssertFalse(try ManifestStore().load(on: volumeDir).items.isEmpty)
    }

    func testTeardownCollectsFailuresWithoutAborting() throws {
        let (manager, mover, _) = makeEnvironment(cacheTargets: makeCacheTargets())

        let source = homeBase.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try mover.move(path: source.path, on: volumeDir, dryRun: false)
        // 외장 사본을 제거해 복원이 실패하도록 만든다.
        try FileManager.default.removeItem(
            at: MacBayPaths.dataRoot(on: volumeDir).appendingPathComponent("Games")
        )

        let report = try manager.execute(volumePath: nil, dryRun: false)

        XCTAssertEqual(report.restored.count, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures[0].path, source.path)
        // 실패가 있어도 설정 정리는 계속된다.
        XCTAssertFalse(report.cacheConfigurationReset)
    }

    func testPartialTeardownKeepsConfiguration() throws {
        // --volume을 지정한 부분 teardown은 셸 설정과 기본 볼륨을 건드리지 않는다.
        let (manager, mover, configStore) = makeEnvironment(cacheTargets: makeCacheTargets())

        let source = homeBase.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try mover.move(path: source.path, on: volumeDir, dryRun: false)

        let zshrc = fakeHome.appendingPathComponent(".zshrc")
        try "# >>> macbay cache >>>\nexport npm_config_cache='/x'\n# <<< macbay cache <<<\n".write(
            to: zshrc, atomically: true, encoding: .utf8
        )
        try configStore.save(MacBayConfig(
            version: MacBayConfig.currentVersion,
            defaultVolume: DefaultVolume(
                path: volumeDir.path, name: "ExtDrive", uuid: "UUID-EXT", savedAt: "2026-09-13T00:00:00Z"
            )
        ))

        let report = try manager.execute(volumePath: volumeDir.path, dryRun: false)

        XCTAssertEqual(report.restored.count, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.cacheConfigurationReset)
        XCTAssertFalse(report.defaultVolumeRemoved)
        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains("macbay cache"))
        XCTAssertNotNil(try configStore.load().defaultVolume)
        XCTAssertTrue(report.notes.contains { $0.contains("single-volume") })
    }

    func testTeardownKeepsUnmountedDefaultVolume() throws {
        // 기본 볼륨이 마운트돼 있지 않으면 저장된 기본 볼륨을 지우지 않는다.
        let (manager, _, configStore) = makeEnvironment(
            cacheTargets: makeCacheTargets(),
            mountedPaths: ["/"]
        )
        let zshrc = fakeHome.appendingPathComponent(".zshrc")
        try "# >>> macbay cache >>>\nexport npm_config_cache='/x'\n# <<< macbay cache <<<\n".write(
            to: zshrc, atomically: true, encoding: .utf8
        )
        try configStore.save(MacBayConfig(
            version: MacBayConfig.currentVersion,
            defaultVolume: DefaultVolume(
                path: volumeDir.path, name: "ExtDrive", uuid: "UUID-EXT", savedAt: "2026-09-13T00:00:00Z"
            )
        ))

        let report = try manager.execute(volumePath: nil, dryRun: false)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.cacheConfigurationReset)
        XCTAssertFalse(report.defaultVolumeRemoved)
        XCTAssertNotNil(try configStore.load().defaultVolume)
        XCTAssertTrue(report.notes.contains { $0.contains("not mounted") })
        XCTAssertTrue(report.notes.contains { $0.contains("was kept") })
    }

    func testTeardownNotesLinksToVolumesOutsideScope() throws {
        // 다른 MacBay 루트를 가리키는 링크가 대상 볼륨에 없으면 조용히 넘기지 않고 알린다.
        let (manager, _, _) = makeEnvironment(cacheTargets: makeCacheTargets())

        let otherVolume = tempDir.appendingPathComponent("OtherDrive")
        let cacheTarget = MacBayPaths.cachesRoot(on: otherVolume).appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: cacheTarget, withIntermediateDirectories: true)
        let cacheLink = fakeHome.appendingPathComponent(".npm")
        try FileManager.default.createSymbolicLink(
            atPath: cacheLink.path,
            withDestinationPath: cacheTarget.path
        )

        let report = try manager.execute(volumePath: nil, dryRun: false)

        XCTAssertTrue(report.notes.contains { $0.contains("Skipped") && $0.contains(".npm") })
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: cacheLink.path))
    }

    func testTeardownWithoutVolumesReportsNotes() throws {
        let (manager, _, _) = makeEnvironment(
            cacheTargets: makeCacheTargets(),
            mountedPaths: ["/"]
        )

        let report = try manager.execute(volumePath: nil, dryRun: false)
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.notes.contains { $0.contains("No eligible external volumes") })
    }
}
