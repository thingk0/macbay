import Foundation
import XCTest
@testable import MacBayKit

final class DirectoryMoveManagerTests: XCTestCase {
    private var tempDir: URL!
    private var homeBase: URL!
    private var volumeDir: URL!
    private var internalDiskInfo: VolumeDiskInfo!
    private var externalDiskInfo: VolumeDiskInfo!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryMoveManagerTests-\(UUID().uuidString)")
        volumeDir = tempDir.appendingPathComponent("ExtDrive")
        try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)

        // move()는 홈 디렉터리 정확히 자체와 ~/Library만 차단하므로,
        // 소스는 실제 홈 아래 유일한 이름의 디렉터리로 만든다.
        homeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacBayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: homeBase, withIntermediateDirectories: true)

        internalDiskInfo = makeDiskInfo(mountPoint: "/", name: "Macintosh HD", isInternal: true)
        externalDiskInfo = makeDiskInfo(mountPoint: volumeDir.path, name: "ExtDrive", isInternal: false)
    }

    override func tearDownWithError() throws {
        // 읽기 전용 디렉터리 케이스가 남을 수 있으므로 쓰기 가능하게 만들고 지운다.
        try? FileManager.default.removeItemMakingWritable(at: tempDir)
        try? FileManager.default.removeItemMakingWritable(at: homeBase)
        try super.tearDownWithError()
    }

    private func makeDiskInfo(mountPoint: String, name: String, isInternal: Bool) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: isInternal ? "Apple Fabric" : "PCI-Express",
            volumeName: name,
            totalBytes: 1_000_000_000_000,
            availableBytes: 500_000_000_000,
            volumeUUID: "UUID-\(name)"
        )
    }

    private func makeManager(
        commandRunner: any CommandRunner = TestBundleCommandRunner(entitlementsXml: "")
    ) -> DirectoryMoveManager {
        let fileManager = MockFileManager(mountedPaths: ["/", volumeDir.path])
        let provider = MockDiskInfoProvider([
            "/": internalDiskInfo,
            volumeDir.path: externalDiskInfo
        ])
        let volumeManager = VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: provider,
            volumeMountPrefix: tempDir.path
        )
        return DirectoryMoveManager(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: volumeManager
        )
    }

    private func makeSourceDirectory(named name: String = "Games") throws -> URL {
        let source = homeBase.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Sub"),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: source.appendingPathComponent("Sub/file.txt"))
        return source
    }

    func testMoveExternalizesDirectoryAndRecordsManifest() throws {
        let manager = makeManager()
        let source = try makeSourceDirectory()

        let result = try manager.move(path: source.path, on: volumeDir, dryRun: false)

        XCTAssertEqual(result.operation, "move")
        XCTAssertEqual(result.sourcePath, source.path)

        let destination = MacBayPaths.dataRoot(on: volumeDir).appendingPathComponent(source.lastPathComponent)
        XCTAssertEqual(result.destinationPath, destination.path)
        XCTAssertEqual(
            try? FileManager.default.destinationOfSymbolicLink(atPath: source.path),
            destination.path
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Sub/file.txt").path
        ))

        let manifest = try ManifestStore().load(on: volumeDir)
        XCTAssertEqual(manifest.items.count, 1)
        XCTAssertEqual(manifest.items[0].kind, .directory)
        XCTAssertEqual(manifest.items[0].sourcePath, source.path)
        XCTAssertEqual(manifest.items[0].externalPath, destination.path)
    }

    func testMoveDryRunChangesNothing() throws {
        let manager = makeManager()
        let source = try makeSourceDirectory()

        let result = try manager.move(path: source.path, on: volumeDir, dryRun: true)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Sub/file.txt").path
        ))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MacBayPaths.dataRoot(on: volumeDir).path
        ))
    }

    func testUnmoveRestoresDirectoryAndDropsManifestRecord() throws {
        let manager = makeManager()
        let source = try makeSourceDirectory()
        _ = try manager.move(path: source.path, on: volumeDir, dryRun: false)

        let result = try manager.unmove(path: source.path, from: nil, dryRun: false)

        XCTAssertEqual(result.operation, "unmove")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Sub/file.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MacBayPaths.dataRoot(on: volumeDir)
                .appendingPathComponent(source.lastPathComponent).path
        ))
        XCTAssertTrue(try ManifestStore().load(on: volumeDir).items.isEmpty)
    }

    func testUnmoveWithoutRecordUsesMacBayLayoutInference() throws {
        // 기록 없이 만들어진 표준 레이아웃 링크도 복원할 수 있어야 한다.
        let source = homeBase.appendingPathComponent("Games")
        let destination = MacBayPaths.dataRoot(on: volumeDir)
            .appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("Sub"),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: destination.appendingPathComponent("Sub/file.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: destination.path)

        let manager = makeManager()
        let result = try manager.unmove(path: source.path, from: nil, dryRun: false)

        XCTAssertEqual(result.destinationPath, source.path)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Sub/file.txt").path
        ))
    }

    func testMoveRejectsProtectedPaths() throws {
        let manager = makeManager()
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 존재하지 않을 수 있는 보호 경로는 미리 만들어 pathMissing 가드를 통과시킨다.
        let candidates = [
            home.appendingPathComponent("Library/Mail").path,
            home.appendingPathComponent("Library/Keychains").path,
            home.appendingPathComponent("Library/Developer").path,
            home.appendingPathComponent("Library/Mobile Documents").path,
            home.appendingPathComponent("Library/Group Containers").path,
            home.appendingPathComponent(".ssh").path,
            home.appendingPathComponent(".cargo").path
        ]
        var created: [URL] = []
        for candidate in candidates
        where !FileManager.default.fileExists(atPath: candidate) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: candidate),
                withIntermediateDirectories: true
            )
            created.append(URL(fileURLWithPath: candidate))
        }
        defer {
            for url in created { try? FileManager.default.removeItem(at: url) }
        }

        for path in ["/", "/System", "/Library", "/Volumes", home.path] + candidates + [
            home.appendingPathComponent("Library/Containers").path,
            home.appendingPathComponent("Library/Application Support").path,
            home.appendingPathComponent("Library/Caches").path
        ] {
            XCTAssertThrowsError(try manager.move(path: path, on: volumeDir, dryRun: false)) { error in
                guard case MacBayError.unsupportedOperation = error else {
                    return XCTFail("Expected unsupportedOperation for \(path), got \(error)")
                }
            }
        }
    }

    func testMoveRejectsManagedCacheTarget() throws {
        let manager = makeManager()
        let goMod = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("go/pkg/mod")
        // 사용자 실제 modcache가 이미 있으면 삭제하면 안 되므로 존재 여부를 먼저 본다.
        let preexisting = FileManager.default.fileExists(atPath: goMod.path)
        if !preexisting {
            try FileManager.default.createDirectory(at: goMod, withIntermediateDirectories: true)
        }
        defer {
            if !preexisting {
                let goRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("go")
                try? FileManager.default.removeItemMakingWritable(at: goMod)
                if !FileManager.default.fileExists(atPath: goRoot.path) ||
                   (try? FileManager.default.contentsOfDirectory(atPath: goRoot.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: goRoot)
                }
            }
        }

        XCTAssertThrowsError(try manager.move(path: goMod.path, on: volumeDir, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(message) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("mb cache"))
        }
    }

    func testMoveHandlesReadOnlyDirectoryContents() throws {
        // Go 모듈 캐시처럼 읽기 전용 하위 디렉터리가 있어도 move가 완료되어야 한다.
        let manager = makeManager()
        let source = homeBase.appendingPathComponent("ModCache")
        let locked = source.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("f.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: locked.path
        )

        _ = try manager.move(path: source.path, on: volumeDir, dryRun: false)

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        let destination = MacBayPaths.dataRoot(on: volumeDir).appendingPathComponent("ModCache")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("locked/f.txt").path
        ))
        // 원본은 백업까지 완전히 제거되어야 한다.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: homeBase.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".ModCache.macbay-") })
    }

    func testMoveRejectsNonDirectoryAndSymlink() throws {
        let manager = makeManager()
        let file = homeBase.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try manager.move(path: file.path, on: volumeDir, dryRun: false)) { error in
            guard case MacBayError.unsupportedOperation = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
        }

        let source = try makeSourceDirectory(named: "Linked")
        let link = homeBase.appendingPathComponent("LinkTarget")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
        XCTAssertThrowsError(try manager.move(path: link.path, on: volumeDir, dryRun: false)) { error in
            guard case MacBayError.unsupportedOperation = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
        }
    }

    func testMoveRejectsAppBundle() throws {
        let manager = makeManager()
        let app = try makeSourceDirectory(named: "Sample.app")
        XCTAssertThrowsError(try manager.move(path: app.path, on: volumeDir, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(message) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("mb dock"))
        }
    }

    func testMoveRejectsExistingDestination() throws {
        let manager = makeManager()
        let source = try makeSourceDirectory()
        _ = try manager.move(path: source.path, on: volumeDir, dryRun: false)

        // 외장 사본이 남아 있으면 동일한 이름으로 다시 move할 수 없어야 한다.
        let recreated = homeBase.appendingPathComponent("Games")
        try FileManager.default.removeItem(at: recreated)
        try FileManager.default.createDirectory(at: recreated, withIntermediateDirectories: true)
        XCTAssertThrowsError(try manager.move(path: recreated.path, on: volumeDir, dryRun: false)) { error in
            guard case MacBayError.destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }
    }

    func testUnmoveRejectsNonManagedLink() throws {
        let manager = makeManager()
        let elsewhere = tempDir.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = homeBase.appendingPathComponent("ForeignLink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: elsewhere.path)

        XCTAssertThrowsError(try manager.unmove(path: link.path, from: nil, dryRun: false)) { error in
            guard case let MacBayError.unsupportedOperation(message) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("outside MacBay storage"))
        }
    }

    func testUnlinkCacheLeavesExternalCopy() throws {
        let manager = makeManager()
        let source = homeBase.appendingPathComponent(".fakecache")
        let target = MacBayPaths.cachesRoot(on: volumeDir).appendingPathComponent("fakecache")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: target.appendingPathComponent("blob"))
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target.path)

        let result = try manager.unlinkCache(source: source, target: target, dryRun: false)

        XCTAssertEqual(result.operation, "unlink cache")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("blob").path))
    }


    func testMoveAndUnmoveKeepOriginalDirectoryModes() throws {
        // 읽기 전용 트리를 옮기느라 권한을 잠시 풀더라도 외장 사본과 복원본은 원래 모드를 유지해야 한다.
        let manager = makeManager(commandRunner: SystemCommandRunner())
        let source = homeBase.appendingPathComponent("Workspace")
        let open = source.appendingPathComponent("open")
        let locked = source.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: open.appendingPathComponent("a.txt"))
        try Data("y".utf8).write(to: locked.appendingPathComponent("b.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        _ = try manager.move(path: source.path, on: volumeDir, dryRun: false)
        let external = MacBayPaths.dataRoot(on: volumeDir).appendingPathComponent("Workspace")
        XCTAssertEqual(try posixMode(of: external.appendingPathComponent("locked")), 0o555)

        _ = try manager.unmove(path: source.path, from: nil, dryRun: false)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        XCTAssertEqual(try posixMode(of: source), 0o755)
        XCTAssertEqual(try posixMode(of: open), 0o755)
        XCTAssertEqual(try posixMode(of: locked), 0o555)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.appendingPathComponent("b.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

    private func posixMode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
