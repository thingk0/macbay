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
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: homeBase)
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

    private func makeManager() -> DirectoryMoveManager {
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
            commandRunner: TestBundleCommandRunner(entitlementsXml: ""),
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
        for path in ["/", "/System", "/Library", "/Volumes", FileManager.default.homeDirectoryForCurrentUser.path] {
            XCTAssertThrowsError(try manager.move(path: path, on: volumeDir, dryRun: false)) { error in
                guard case MacBayError.unsupportedOperation = error else {
                    return XCTFail("Expected unsupportedOperation for \(path), got \(error)")
                }
            }
        }
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
}
