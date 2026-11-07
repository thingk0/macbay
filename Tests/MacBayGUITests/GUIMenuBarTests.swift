import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIMenuBarTests: XCTestCase {
    func testFirstLaunchAndUnknownPreferencesUseConnectedGaugesAndPercentage() {
        XCTAssertEqual(GUIMenuBarDisplay(storedValue: nil), .connected)
        XCTAssertEqual(GUIMenuBarDisplay(storedValue: "invalid"), .connected)
        XCTAssertEqual(GUIMenuBarMetric(storedValue: nil), .usedPercentage)
        XCTAssertEqual(GUIMenuBarMetric(storedValue: "invalid"), .usedPercentage)
        XCTAssertEqual(GUIMenuBarDisplay(storedValue: "combined"), .combined)
        XCTAssertEqual(GUIMenuBarMetric(storedValue: "availableSpace"), .availableSpace)
    }

    func testCombinedPercentageIsWeightedByCapacity() {
        let snapshot = makeSnapshot(internalFree: 10, externalFree: 900)
        XCTAssertEqual(snapshot.title(display: .connected, metric: .usedPercentage), "90% · 10%")
        XCTAssertEqual(snapshot.title(display: .combined, metric: .usedPercentage), "17%")
        XCTAssertEqual(snapshot.combinedCapacity?.availableBytes, 910)
    }

    func testDisconnectRemovesExternalCapacityInsteadOfKeepingStaleValues() {
        let snapshot = makeSnapshot(externalPath: nil, connected: false)
        XCTAssertEqual(snapshot.connection, "Disconnected")
        XCTAssertEqual(snapshot.title(display: .connected, metric: .usedPercentage), "75% · —")
        XCTAssertEqual(snapshot.title(display: .combined, metric: .usedPercentage), "75%")
        XCTAssertEqual(snapshot.combinedCapacity?.availableBytes, 25)
        XCTAssertNil(snapshot.externalCapacity)
    }

    func testUnselectedAndMissingDefaultDrivesAreNeverIncludedInTheSum() {
        let unselected = makeSnapshot(externalPath: nil)
        XCTAssertEqual(unselected.connection, "Choose a drive")
        XCTAssertEqual(unselected.combinedCapacity?.totalBytes, 100)
        let missing = makeSnapshot(externalPath: nil, defaultVolume: StatusDefaultVolume(name: "Missing", path: "/Volumes/Missing"))
        XCTAssertEqual(missing.connection, "Disconnected")
        XCTAssertEqual(missing.externalName, "Missing")
        XCTAssertNil(missing.externalCapacity)
    }

    func testReadFailureAndLoadingHaveNoInventedCapacity() {
        let loading = GUIMenuBarSnapshot(status: nil, selectedVolumePath: nil, error: nil)
        XCTAssertEqual(loading.connection, "Reading storage…")
        XCTAssertEqual(loading.title(display: .connected, metric: .usedPercentage), "— · —")
        let failed = GUIMenuBarSnapshot(status: GUIExamples.status, selectedVolumePath: "/Volumes/KLEVV", error: "Disk read failed")
        XCTAssertEqual(failed.title(display: .combined, metric: .availableSpace), "—")
        XCTAssertNil(failed.internalCapacity)
        XCTAssertNil(failed.externalCapacity)
        XCTAssertTrue(failed.toolTip.contains("Disk read failed"))
    }

    func testUnknownCapacityIsNotShownAsEmptyAndInvalidFreeSpaceIsClamped() {
        let unknown = GUIMenuBarCapacity(StorageVolume(name: "Unknown", path: "/", isInternal: true, totalBytes: 0, availableBytes: 0))
        XCTAssertNil(unknown.usedFraction)
        XCTAssertEqual(unknown.percentageText, "—")
        XCTAssertNil(unknown.combined(with: GUIMenuBarCapacity(GUIExamples.status.internalVolume)))
        let invalid = GUIMenuBarCapacity(StorageVolume(name: "Invalid", path: "/", isInternal: true, totalBytes: 100, availableBytes: 120))
        XCTAssertEqual(invalid.percentageText, "0%")
        XCTAssertEqual(invalid.availableBytes, 100)
    }

    func testAvailableSpaceUsesTheSameUnitFormatterAsTheWindow() {
        let snapshot = makeSnapshot(internalFree: 25, externalFree: 700)
        XCTAssertEqual(snapshot.title(display: .connected, metric: .availableSpace), GUIFormat.bytes(25) + " · " + GUIFormat.bytes(700))
        XCTAssertEqual(snapshot.title(display: .combined, metric: .availableSpace), GUIFormat.bytes(725))
    }

    private func makeSnapshot(internalFree: UInt64 = 25, externalFree: UInt64 = 700,
                              externalPath: String? = "/Volumes/Example", connected: Bool = true,
                              defaultVolume: StatusDefaultVolume? = nil) -> GUIMenuBarSnapshot {
        let internalVolume = StorageVolume(name: "Mac", path: "/", isInternal: true, totalBytes: 100, availableBytes: internalFree)
        let external = StorageVolume(name: "Example", path: "/Volumes/Example", isInternal: false, totalBytes: 1000, availableBytes: externalFree)
        return GUIMenuBarSnapshot(status: StatusReport(generatedAt: "", internalVolume: internalVolume,
            externalVolumes: connected ? [external] : [], defaultVolume: defaultVolume, dockedItems: []),
            selectedVolumePath: externalPath, error: nil)
    }
}
