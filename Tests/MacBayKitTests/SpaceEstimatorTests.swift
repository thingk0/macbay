import Foundation
import XCTest
@testable import MacBayKit

final class SpaceEstimatorTests: XCTestCase {
    private let volumeURL = URL(fileURLWithPath: "/Volumes/ExternalSSD")

    private func makeInfo(
        mountPoint: String,
        totalBytes: UInt64 = 1_000_000_000_000,
        availableBytes: UInt64
    ) -> VolumeDiskInfo {
        VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "PCI-Express",
            volumeName: URL(fileURLWithPath: mountPoint).lastPathComponent,
            totalBytes: totalBytes,
            availableBytes: availableBytes
        )
    }

    private func estimator(availableBytes: UInt64) -> SpaceEstimator {
        SpaceEstimator(diskInfoProvider: MockDiskInfoProvider([
            volumeURL.path: makeInfo(mountPoint: volumeURL.path, availableBytes: availableBytes)
        ]))
    }

    func testSufficientSpaceEstimate() throws {
        let estimate = estimator(availableBytes: 900_000_000_000).estimate(
            copyBytes: 100_000_000_000,
            destinationVolume: volumeURL,
            internalFreedBytes: 100_000_000_000
        )

        XCTAssertTrue(estimate.isVerifiable)
        XCTAssertTrue(estimate.isSufficient)
        XCTAssertEqual(estimate.shortfallBytes, 0)
        XCTAssertEqual(estimate.destinationFreeAfterCopyBytes, 800_000_000_000)

        let lines = estimate.reportLines()
        XCTAssertTrue(lines.contains { $0.contains("Space: destination free 838.2 GB on /Volumes/ExternalSSD") })
        XCTAssertTrue(lines.contains { $0.contains("Space: estimated free after copy 745.1 GB") })
        XCTAssertTrue(lines.contains { $0.contains("Space: estimated internal space freed 93.1 GB") })
        XCTAssertTrue(lines.contains { $0.contains("APFS shared blocks and snapshots") })
        XCTAssertFalse(lines.contains { $0.contains("insufficient") })
    }

    func testInsufficientSpaceReportsShortfall() throws {
        let estimate = estimator(availableBytes: 100).estimate(
            copyBytes: 500,
            destinationVolume: volumeURL
        )

        XCTAssertTrue(estimate.isVerifiable)
        XCTAssertFalse(estimate.isSufficient)
        XCTAssertEqual(estimate.shortfallBytes, 400)
        XCTAssertEqual(estimate.destinationFreeAfterCopyBytes, -400)

        let lines = estimate.reportLines()
        XCTAssertTrue(lines.contains { $0.contains("Space: insufficient — 400 B short on /Volumes/ExternalSSD") })
        XCTAssertTrue(lines.contains { $0.contains("Space: estimated free after copy -400 B") })
        XCTAssertFalse(lines.contains { $0.contains("internal space freed") })
    }

    func testExactFitCountsAsSufficient() throws {
        let estimate = estimator(availableBytes: 1024).estimate(
            copyBytes: 1024,
            destinationVolume: volumeURL
        )

        XCTAssertTrue(estimate.isSufficient)
        XCTAssertEqual(estimate.shortfallBytes, 0)
        XCTAssertEqual(estimate.destinationFreeAfterCopyBytes, 0)
        XCTAssertFalse(estimate.reportLines().contains { $0.contains("insufficient") })
    }

    func testUnknownCapacityIsNotVerifiable() throws {
        let unknownInfo = makeInfo(mountPoint: volumeURL.path, totalBytes: 0, availableBytes: 0)
        let estimator = SpaceEstimator(diskInfoProvider: MockDiskInfoProvider([volumeURL.path: unknownInfo]))

        let estimate = estimator.estimate(copyBytes: 500, destinationVolume: volumeURL)

        XCTAssertFalse(estimate.isVerifiable)
        XCTAssertFalse(estimate.isSufficient)
        XCTAssertNil(estimate.destinationAvailableBytes)
        XCTAssertNil(estimate.destinationFreeAfterCopyBytes)
        XCTAssertEqual(estimate.shortfallBytes, 0)

        let lines = estimate.reportLines()
        XCTAssertTrue(lines.contains { $0.contains("Space: free space on /Volumes/ExternalSSD could not be read; a real run stops before copying") })
        XCTAssertFalse(lines.contains { $0.contains("insufficient") })
    }

    func testUnmappedVolumeIsNotVerifiable() throws {
        let estimate = SpaceEstimator(diskInfoProvider: MockDiskInfoProvider([:])).estimate(
            copyBytes: 500,
            destinationVolume: volumeURL
        )

        XCTAssertFalse(estimate.isVerifiable)
    }

    func testRequireSufficientSpacePassesOnBoundary() throws {
        XCTAssertNoThrow(try estimator(availableBytes: 2048).requireSufficientSpace(
            copyBytes: 2048,
            destinationVolume: volumeURL
        ))
    }

    func testRequireSufficientSpaceThrowsWhenShort() throws {
        XCTAssertThrowsError(try estimator(availableBytes: 1024).requireSufficientSpace(
            copyBytes: 4096,
            destinationVolume: volumeURL
        )) { error in
            guard case let MacBayError.insufficientSpace(path, neededBytes, availableBytes) = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
            XCTAssertEqual(path, volumeURL.path)
            XCTAssertEqual(neededBytes, 4096)
            XCTAssertEqual(availableBytes, 1024)
        }
    }

    func testRequireSufficientSpaceThrowsWhenCapacityIsUnknown() throws {
        let unknownInfo = makeInfo(mountPoint: volumeURL.path, totalBytes: 0, availableBytes: 0)
        let estimator = SpaceEstimator(diskInfoProvider: MockDiskInfoProvider([volumeURL.path: unknownInfo]))

        XCTAssertThrowsError(try estimator.requireSufficientSpace(copyBytes: 1, destinationVolume: volumeURL)) { error in
            guard case let MacBayError.spaceCheckFailed(path, details) = error else {
                return XCTFail("Expected spaceCheckFailed, got \(error)")
            }
            XCTAssertEqual(path, volumeURL.path)
            XCTAssertTrue(details.contains("Capacity information is unavailable"))
        }
    }

    func testRequireSufficientSpaceThrowsWhenDiskInfoFails() throws {
        let estimator = SpaceEstimator(diskInfoProvider: MockDiskInfoProvider([:]))

        XCTAssertThrowsError(try estimator.requireSufficientSpace(copyBytes: 1, destinationVolume: volumeURL)) { error in
            guard case MacBayError.spaceCheckFailed = error else {
                return XCTFail("Expected spaceCheckFailed, got \(error)")
            }
        }
    }

    func testSpaceErrorCodesAndMessages() {
        let insufficient = MacBayError.insufficientSpace(path: "/Volumes/X", neededBytes: 2048, availableBytes: 1024)
        XCTAssertEqual(insufficient.errorCode, "retryable_error")
        XCTAssertEqual(insufficient.errorDescription, "Not enough space on /Volumes/X: need 2.0 KB, available 1.0 KB")
        XCTAssertEqual(insufficient.errorDetails, "Need 2.0 KB, available 1.0 KB")

        let failed = MacBayError.spaceCheckFailed(path: "/Volumes/X", details: "diskutil failed")
        XCTAssertEqual(failed.errorCode, "execution_error")
        XCTAssertEqual(failed.errorDescription, "Unable to verify free space on /Volumes/X: diskutil failed")
    }

    func testHumanSignedBytesFormatting() {
        XCTAssertEqual(OutputFormatter.humanSignedBytes(0), "0 B")
        XCTAssertEqual(OutputFormatter.humanSignedBytes(-400), "-400 B")
        XCTAssertEqual(OutputFormatter.humanSignedBytes(1024), "1.0 KB")
        XCTAssertEqual(OutputFormatter.humanSignedBytes(Int64.min), "-8388608.0 TB")
    }
}
