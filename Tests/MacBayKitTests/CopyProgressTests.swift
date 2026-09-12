import Foundation
import XCTest
@testable import MacBayKit

final class CopyProgressTests: XCTestCase {
    func testSamplerCountsRegularFilesWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: target.appendingPathComponent("file"))
        let other = root.appendingPathComponent("other")
        try Data(repeating: 2, count: 128).write(to: other)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("link"), withDestinationURL: other)
        var sampler = CopyProgressSampler(destination: target, totalBytes: 256)
        let sample = try XCTUnwrap(sampler.sample())
        XCTAssertEqual(sample.observedBytes, 64)
        XCTAssertEqual(sample.fraction, 0.25)
        XCTAssertNil(sampler.sample(), "Sampling should be throttled")
    }

    func testUnavailableDestinationAndUnknownTotalDoNotClaimCompletion() {
        var sampler = CopyProgressSampler(destination: URL(fileURLWithPath: "/tmp/absent-\(UUID().uuidString)"), totalBytes: 100)
        XCTAssertNil(sampler.sample())
        XCTAssertEqual(CopyProgress(observedBytes: 100, totalBytes: 0, elapsed: 0).fraction, 0)
        let sample = CopyProgress(observedBytes: 200, totalBytes: 100, elapsed: 2)
        XCTAssertEqual(sample.observedBytes, 100)
        XCTAssertEqual(sample.fraction, 0.99)
        XCTAssertEqual(sample.bytesPerSecond, 50)
    }

    func testCommandHeartbeatPreservesOutputAndExitStatus() throws {
        var samples = 0
        let result = try SystemCommandRunner().run("/bin/sh", arguments: ["-c", "sleep 0.3; printf result; printf failure >&2; exit 7"], heartbeat: { samples += 1 })
        XCTAssertGreaterThan(samples, 0)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutput, "result")
        XCTAssertEqual(result.standardError, "failure")
    }
}
