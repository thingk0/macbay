import XCTest
@testable import MacBayKit

final class OutputFormatterTests: XCTestCase {
    private func sampleVolume(
        name: String = "TestVolume",
        path: String = "/Volumes/TestVolume",
        isInternal: Bool = false,
        totalBytes: UInt64,
        availableBytes: UInt64
    ) -> StorageVolume {
        StorageVolume(
            name: name,
            path: path,
            isInternal: isInternal,
            totalBytes: totalBytes,
            availableBytes: availableBytes
        )
    }

    private func makeReport(
        internalVolume: StorageVolume? = nil,
        externalVolumes: [StorageVolume] = [],
        dockedItems: [DockedItem] = [],
        warnings: [String] = []
    ) -> StatusReport {
        StatusReport(
            generatedAt: "2026-09-10T12:00:00Z",
            internalVolume: internalVolume ?? sampleVolume(
                name: "Macintosh HD",
                path: "/",
                isInternal: true,
                totalBytes: 200 * 1024 * 1024 * 1024,
                availableBytes: 100 * 1024 * 1024 * 1024
            ),
            externalVolumes: externalVolumes,
            dockedItems: dockedItems,
            warnings: warnings
        )
    }

    func testUsageBarZeroPercent() {
        let formatter = OutputFormatter(useColor: true)
        let internalVol = sampleVolume(
            name: "Macintosh HD",
            path: "/",
            isInternal: true,
            totalBytes: 1000,
            availableBytes: 1000
        )
        let report = makeReport(internalVolume: internalVol)
        let output = formatter.status(report)

        // 0% usage -> 0 filled, 20 empty blocks
        let emptyBar = String(repeating: "░", count: 20)
        XCTAssertTrue(output.contains(emptyBar))
        XCTAssertTrue(output.contains("0.0% used"))
        XCTAssertTrue(output.contains("Used: 0 B / 1000 B"))
        XCTAssertTrue(output.contains("Free: 1000 B"))

        // Under 80% should use cyan (36)
        XCTAssertTrue(output.contains("\u{001B}[36m\(emptyBar)\u{001B}[0m"))
    }

    func testUsageBarHundredPercent() {
        let formatter = OutputFormatter(useColor: true)
        let internalVol = sampleVolume(
            name: "Macintosh HD",
            path: "/",
            isInternal: true,
            totalBytes: 1000,
            availableBytes: 0
        )
        let report = makeReport(internalVolume: internalVol)
        let output = formatter.status(report)

        // 100% usage -> 20 filled, 0 empty blocks
        let fullBar = String(repeating: "█", count: 20)
        XCTAssertTrue(output.contains(fullBar))
        XCTAssertTrue(output.contains("100.0% used"))
        XCTAssertTrue(output.contains("Used: 1000 B / 1000 B"))
        XCTAssertTrue(output.contains("Free: 0 B"))

        // >= 90% should use red (31)
        XCTAssertTrue(output.contains("\u{001B}[31m\(fullBar)\u{001B}[0m"))
    }

    func testColorBoundariesCyanYellowRed() {
        // 79.9% -> Cyan (36)
        let volCyan = sampleVolume(totalBytes: 10_000, availableBytes: 2_010)
        let reportCyan = makeReport(internalVolume: volCyan)
        let outCyan = OutputFormatter(useColor: true).status(reportCyan)
        let bar16 = String(repeating: "█", count: 16) + String(repeating: "░", count: 4)
        XCTAssertTrue(outCyan.contains("\u{001B}[36m\(bar16)\u{001B}[0m"))

        // 80.0% -> Yellow (33)
        let volYellow1 = sampleVolume(totalBytes: 1_000, availableBytes: 200)
        let reportYellow1 = makeReport(internalVolume: volYellow1)
        let outYellow1 = OutputFormatter(useColor: true).status(reportYellow1)
        XCTAssertTrue(outYellow1.contains("\u{001B}[33m\(bar16)\u{001B}[0m"))

        // 89.9% -> Yellow (33)
        let volYellow2 = sampleVolume(totalBytes: 10_000, availableBytes: 1_010)
        let reportYellow2 = makeReport(internalVolume: volYellow2)
        let outYellow2 = OutputFormatter(useColor: true).status(reportYellow2)
        let bar18 = String(repeating: "█", count: 18) + String(repeating: "░", count: 2)
        XCTAssertTrue(outYellow2.contains("\u{001B}[33m\(bar18)\u{001B}[0m"))

        // 90.0% -> Red (31)
        let volRed = sampleVolume(totalBytes: 1_000, availableBytes: 100)
        let reportRed = makeReport(internalVolume: volRed)
        let outRed = OutputFormatter(useColor: true).status(reportRed)
        XCTAssertTrue(outRed.contains("\u{001B}[31m\(bar18)\u{001B}[0m"))
    }

    func testZeroTotalCapacityShowsUnavailable() {
        let formatter = OutputFormatter(useColor: false)
        let zeroVol = sampleVolume(totalBytes: 0, availableBytes: 0)
        let report = makeReport(internalVolume: zeroVol)
        let output = formatter.status(report)

        XCTAssertTrue(output.contains("Capacity unavailable"))
        XCTAssertFalse(output.contains("% used"))
        XCTAssertTrue(output.contains("Used: 0 B / 0 B"))
        XCTAssertTrue(output.contains("Free: 0 B"))
    }

    func testAbnormalCapacityAvailableGreaterThanTotalIsClamped() {
        let formatter = OutputFormatter(useColor: false)
        let abnormalVol = sampleVolume(totalBytes: 1_000, availableBytes: 5_000)
        let report = makeReport(internalVolume: abnormalVol)
        let output = formatter.status(report)

        XCTAssertTrue(output.contains("0.0% used"))
        XCTAssertTrue(output.contains("Used: 0 B / 1000 B"))
        XCTAssertTrue(output.contains("Free: 1000 B"))
    }

    func testNoExternalVolumesShowsNoneDetectedWithCount() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport(externalVolumes: [])
        let output = formatter.status(report)

        XCTAssertTrue(output.contains("External volumes · 0"))
        XCTAssertTrue(output.contains("  None detected"))
    }

    func testMultipleExternalVolumesFormattedIndividually() {
        let formatter = OutputFormatter(useColor: false)
        let ext1 = sampleVolume(name: "SSD_Primary", path: "/Volumes/SSD_Primary", totalBytes: 1_000_000, availableBytes: 400_000)
        let ext2 = sampleVolume(name: "Backup_HDD", path: "/Volumes/Backup_HDD", totalBytes: 2_000_000, availableBytes: 200_000)
        let report = makeReport(externalVolumes: [ext1, ext2])
        let output = formatter.status(report)

        XCTAssertTrue(output.contains("External · SSD_Primary"))
        XCTAssertTrue(output.contains("  /Volumes/SSD_Primary"))
        XCTAssertTrue(output.contains("External · Backup_HDD"))
        XCTAssertTrue(output.contains("  /Volumes/Backup_HDD"))
    }

    func testLongVolumeNameAndPath() {
        let formatter = OutputFormatter(useColor: false)
        let longName = "Ultra_Extreme_High_Speed_NVMe_External_Storage_Drive_2026_Edition"
        let longPath = "/Volumes/Very/Long/Deeply/Nested/Custom/Mount/Point/Directory/Path"
        let ext = sampleVolume(name: longName, path: longPath, totalBytes: 1_000_000, availableBytes: 500_000)
        let report = makeReport(externalVolumes: [ext])
        let output = formatter.status(report)

        XCTAssertTrue(output.contains("External · \(longName)"))
        XCTAssertTrue(output.contains("  \(longPath)"))
    }

    func testDockedItemsAndWarningsPresenceAndAbsence() {
        let formatter = OutputFormatter(useColor: false)

        // Case 1: Empty docked items and no warnings
        let emptyReport = makeReport(dockedItems: [], warnings: [])
        let emptyOutput = formatter.status(emptyReport)
        XCTAssertTrue(emptyOutput.contains("Docked items · 0"))
        XCTAssertTrue(emptyOutput.contains("  None"))
        XCTAssertFalse(emptyOutput.contains("Warnings"))

        // Case 2: Docked items and warnings present
        let dockedItem = DockedItem(
            name: "HeavyApp.app",
            sourcePath: "/Applications/HeavyApp.app",
            externalPath: "/Volumes/SSD/MacBay/Applications/HeavyApp.app",
            sizeBytes: 1024 * 1024 * 1024,
            kind: .application,
            dockedAt: "2026-09-10T12:00:00Z"
        )
        let warning = "Excluded volume 'DiskImage' (/Volumes/DiskImage): Disk image volumes are not supported"
        let populatedReport = makeReport(dockedItems: [dockedItem], warnings: [warning])
        let populatedOutput = formatter.status(populatedReport)

        XCTAssertTrue(populatedOutput.contains("Docked items · 1"))
        XCTAssertTrue(populatedOutput.contains("• HeavyApp.app — 1.0 GB (/Volumes/SSD/MacBay/Applications/HeavyApp.app)"))
        XCTAssertTrue(populatedOutput.contains("Warnings · 1"))
        XCTAssertTrue(populatedOutput.contains("• \(warning)"))
    }

    func testColorSupportDetection() {
        // Not a TTY -> always false
        XCTAssertFalse(OutputFormatter.isColorSupported(isTTY: false, environment: [:]))
        XCTAssertFalse(OutputFormatter.isColorSupported(isTTY: false, environment: ["TERM": "xterm-256color"]))

        // TTY + NO_COLOR present -> false
        XCTAssertFalse(OutputFormatter.isColorSupported(isTTY: true, environment: ["NO_COLOR": "1"]))
        XCTAssertFalse(OutputFormatter.isColorSupported(isTTY: true, environment: ["NO_COLOR": ""]))

        // TTY + TERM=dumb -> false
        XCTAssertFalse(OutputFormatter.isColorSupported(isTTY: true, environment: ["TERM": "dumb"]))

        // TTY + no NO_COLOR + valid TERM -> true
        XCTAssertTrue(OutputFormatter.isColorSupported(isTTY: true, environment: ["TERM": "xterm-256color"]))
        XCTAssertTrue(OutputFormatter.isColorSupported(isTTY: true, environment: [:]))
    }

    func testNoColorSettingProducesNoAnsiEscapes() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport()
        let output = formatter.status(report)

        XCTAssertFalse(output.contains("\u{001B}"))
    }
}
