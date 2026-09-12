import Foundation
import XCTest
@testable import MacBayKit

final class VolumeOperationLockTests: XCTestCase {
    private var tempDir: URL!
    private var volumeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        volumeURL = tempDir.appendingPathComponent("TestVolume")
        try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLockPathAndFileCreated() throws {
        let lock = VolumeOperationLock()
        let lockURL = MacBayPaths.operationLockURL(on: volumeURL)
        XCTAssertEqual(lockURL.lastPathComponent, ".macbay.lock")
        XCTAssertEqual(lockURL.deletingLastPathComponent().lastPathComponent, "MacBay")

        var executed = false
        try lock.withVolumeLock(on: volumeURL) {
            executed = true
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        }

        XCTAssertTrue(executed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testBodyReturnValueAndErrorPropagateUnchanged() throws {
        let lock = VolumeOperationLock()

        // 1. Return value propagates
        let result = try lock.withVolumeLock(on: volumeURL) {
            "expected_value"
        }
        XCTAssertEqual(result, "expected_value")

        // 2. Body error propagates unchanged (no volumeBusy translation)
        XCTAssertThrowsError(try lock.withVolumeLock(on: volumeURL) {
            throw MacBayError.invalidApplication("custom-app")
        }) { error in
            guard case MacBayError.invalidApplication(let app) = error else {
                XCTFail("Expected invalidApplication, got \(error)")
                return
            }
            XCTAssertEqual(app, "custom-app")
        }
    }

    func testRawFileLockNonBlockingThrowsOperationInProgress() throws {
        let lockFile = tempDir.appendingPathComponent("test.lock")
        let lock1 = FileLock(url: lockFile)
        let lock2 = FileLock(url: lockFile)

        try lock1.withLock(blocking: true) {
            XCTAssertThrowsError(try lock2.withLock(blocking: false) {
                XCTFail("Should not acquire non-blocking lock while held")
            }) { error in
                guard case MacBayError.operationInProgress(let path, _) = error else {
                    XCTFail("Expected operationInProgress, got \(error)")
                    return
                }
                XCTAssertEqual(path, lockFile.path)
            }
        }
    }

    func testConcurrentThreadsFailClosedWithVolumeBusy() throws {
        let lock = VolumeOperationLock()
        let lockURL = MacBayPaths.operationLockURL(on: volumeURL)
        let thread1Started = DispatchSemaphore(value: 0)
        let thread2Done = DispatchSemaphore(value: 0)
        var thread2Error: Error?

        let thread1 = Thread {
            do {
                try lock.withVolumeLock(on: self.volumeURL) {
                    thread1Started.signal()
                    _ = thread2Done.wait(timeout: .now() + 5)
                }
            } catch {
                XCTFail("Thread 1 failed: \(error)")
            }
        }
        thread1.start()

        _ = thread1Started.wait(timeout: .now() + 5)

        let thread2 = Thread {
            do {
                try lock.withVolumeLock(on: self.volumeURL) {
                    XCTFail("Thread 2 should not acquire volume lock while Thread 1 holds it")
                }
            } catch {
                thread2Error = error
            }
            thread2Done.signal()
        }
        thread2.start()

        _ = thread2Done.wait(timeout: .now() + 5)

        guard let mbError = thread2Error as? MacBayError else {
            return XCTFail("Expected MacBayError on thread 2, got \(String(describing: thread2Error))")
        }
        guard case MacBayError.volumeBusy(let path, let locks) = mbError else {
            return XCTFail("Expected volumeBusy on thread 2, got \(mbError)")
        }
        XCTAssertEqual(path, volumeURL.path)
        XCTAssertEqual(locks, [lockURL.path])
    }

    func testVolumeOperationLockThrowsVolumeBusyWhenRawFileLockHeld() throws {
        let lockURL = MacBayPaths.operationLockURL(on: volumeURL)
        let rawLock = FileLock(url: lockURL)

        try rawLock.withLock(blocking: true) {
            XCTAssertThrowsError(try VolumeOperationLock().withVolumeLock(on: volumeURL) {
                XCTFail("Should not acquire volume lock when raw lock is held")
            }) { error in
                guard let mbError = error as? MacBayError else {
                    XCTFail("Expected MacBayError, got \(error)")
                    return
                }
                XCTAssertEqual(mbError.errorCode, "retryable_error")
                guard case MacBayError.volumeBusy(let path, let locks) = mbError else {
                    XCTFail("Expected volumeBusy, got \(mbError)")
                    return
                }
                XCTAssertEqual(path, volumeURL.path)
                XCTAssertEqual(locks, [lockURL.path])
            }
        }
    }

    func testReentrancyOnSameVolumeSucceedsAndReleases() throws {
        let lock = VolumeOperationLock()
        var innerExecuted = false

        try lock.withVolumeLock(on: volumeURL) {
            try lock.withVolumeLock(on: volumeURL) {
                innerExecuted = true
            }
        }
        XCTAssertTrue(innerExecuted)

        // After completion, the lock is released. A raw lock can be acquired and will block VolumeOperationLock.
        let lockURL = MacBayPaths.operationLockURL(on: volumeURL)
        try FileLock(url: lockURL).withLock(blocking: true) {
            XCTAssertThrowsError(try VolumeOperationLock().withVolumeLock(on: volumeURL) {
                XCTFail("Should fail because raw lock is held")
            }) { error in
                guard case MacBayError.volumeBusy = error else {
                    XCTFail("Expected volumeBusy, got \(error)")
                    return
                }
            }
        }
    }

    func testNoOpVolumeOperationLock() throws {
        let noop = NoOpVolumeOperationLock()
        let emptyVol = tempDir.appendingPathComponent("NoOpVol")
        var executed = false

        let result = try noop.withVolumeLock(on: emptyVol) {
            executed = true
            return 999
        }

        XCTAssertEqual(result, 999)
        XCTAssertTrue(executed)

        let lockURL = MacBayPaths.operationLockURL(on: emptyVol)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }
}
