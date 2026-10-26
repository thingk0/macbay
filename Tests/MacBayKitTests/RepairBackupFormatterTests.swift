import XCTest
@testable import MacBayKit

final class RepairBackupFormatterTests: XCTestCase {
    private func makeInventory(entries: [RepairBackupEntry]) -> RepairBackupInventory {
        RepairBackupInventory(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            backupsRoot: "/Volumes/ExternalSSD/MacBay/Backups",
            backups: entries,
            summary: RepairBackupSummary(
                count: entries.count,
                totalSizeBytes: entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
                referencedCount: entries.filter { $0.state == .referenced }.count,
                unverifiableCount: entries.filter { $0.state == .unverifiable }.count
            ),
            notes: ["Sizes are logical; APFS shared blocks and snapshots can change the actual free space."],
            warnings: []
        )
    }

    func testInventoryHumanOutputShowsMetadataAndState() throws {
        let entry = RepairBackupEntry(
            id: "6f2c1b9a-1111-2222-3333-444455556666",
            appName: "Kiro CLI.app",
            path: "/Volumes/ExternalSSD/MacBay/Backups/6f2c1b9a-1111-2222-3333-444455556666/Kiro CLI.app",
            version: "1.1.0",
            buildNumber: "110",
            savedAt: "2026-10-12T10:55:00Z",
            sizeBytes: 103_000_000,
            state: .unreferenced
        )

        let output = OutputFormatter(useColor: false).backups(makeInventory(entries: [entry]))

        XCTAssertTrue(output.contains("MacBay backups"))
        XCTAssertTrue(output.contains("Kiro CLI.app"))
        XCTAssertTrue(output.contains("1.1.0 (110)"))
        XCTAssertTrue(output.contains("Unreferenced"))
        XCTAssertTrue(output.contains("98.2 MB"))
        XCTAssertTrue(output.contains("Sizes are logical"))
        XCTAssertFalse(output.contains("\u{001B}"))
    }

    func testInventoryHumanOutputShowsProtectionDetails() throws {
        let referenced = RepairBackupEntry(
            id: "aaaaaaaa-1111-2222-3333-444455556666",
            appName: "Referenced.app",
            path: "/Volumes/ExternalSSD/MacBay/Backups/aaaaaaaa-1111-2222-3333-444455556666/Referenced.app",
            version: "2.0.0",
            savedAt: "2026-10-11T09:00:00Z",
            sizeBytes: 2048,
            state: .referenced,
            referencedBy: "/Volumes/ExternalSSD/MacBay/.operations/repair-Referenced.app.json"
        )
        let unverifiable = RepairBackupEntry(
            id: "bbbbbbbb-1111-2222-3333-444455556666",
            appName: "Unknown.app",
            path: "/Volumes/ExternalSSD/MacBay/Backups/bbbbbbbb-1111-2222-3333-444455556666",
            state: .unverifiable,
            reason: "The operation directory is a symbolic link and was not followed."
        )

        let output = OutputFormatter(useColor: false).backups(makeInventory(entries: [referenced, unverifiable]))

        XCTAssertTrue(output.contains("Referenced"))
        XCTAssertTrue(output.contains("referenced by:"))
        XCTAssertTrue(output.contains("Unverifiable"))
        XCTAssertTrue(output.contains("reason: The operation directory is a symbolic link"))
        XCTAssertTrue(output.contains("protected from removal"))
    }

    func testRemovalPlanShowsSelectedRefusedAndDryRunNotice() throws {
        let selected = RepairBackupEntry(
            id: "cccccccc-1111-2222-3333-444455556666",
            appName: "Old.app",
            path: "/Volumes/ExternalSSD/MacBay/Backups/cccccccc-1111-2222-3333-444455556666/Old.app",
            version: "1.0.0",
            savedAt: "2026-10-10T08:00:00Z",
            sizeBytes: 5_000_000,
            state: .unreferenced
        )
        let plan = RepairBackupRemovalPlan(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            requestedIDs: [selected.id, "missing"],
            selected: [selected],
            refused: [
                RepairBackupRemovalRefusal(id: "missing", reason: "No backup with this operation ID was found on the volume.")
            ],
            totalBytes: 5_000_000,
            notes: ["Removal is permanent; MacBay does not keep another copy of a removed backup."]
        )

        let output = OutputFormatter(useColor: false).backupRemovalPlan(plan, dryRun: true)

        XCTAssertTrue(output.contains("Dry run: remove repair backups"))
        XCTAssertTrue(output.contains("Old.app"))
        XCTAssertTrue(output.contains("Selected · 1"))
        XCTAssertTrue(output.contains("Refused · 1"))
        XCTAssertTrue(output.contains("No backup with this operation ID"))
        XCTAssertTrue(output.contains("Dry run: no files were changed"))
        XCTAssertFalse(output.contains("\u{001B}"))
    }

    func testRemovalResultShowsReclaimedSpaceAndFailures() throws {
        let removed = RepairBackupEntry(
            id: "dddddddd-1111-2222-3333-444455556666",
            appName: "Removed.app",
            path: "/Volumes/ExternalSSD/MacBay/Backups/dddddddd-1111-2222-3333-444455556666/Removed.app",
            sizeBytes: 10_000_000,
            state: .unreferenced
        )
        let result = RepairBackupRemovalResult(
            generatedAt: "2026-10-12T10:55:00Z",
            volumeName: "ExternalSSD",
            volumePath: "/Volumes/ExternalSSD",
            removed: [removed],
            refused: [],
            failed: [
                RepairBackupRemovalFailure(
                    id: "eeeeeeee-1111-2222-3333-444455556666",
                    appName: "Failed.app",
                    path: "/Volumes/ExternalSSD/MacBay/Backups/eeeeeeee-1111-2222-3333-444455556666/Failed.app",
                    reason: "simulated failure"
                )
            ],
            reclaimedBytes: 10_000_000,
            freeBytesBefore: 100_000_000_000,
            freeBytesAfter: 100_010_000_000,
            notes: ["Sizes are logical; APFS shared blocks and snapshots can change the actual free space."]
        )

        let output = OutputFormatter(useColor: false).backupRemovalResult(result)

        XCTAssertTrue(output.contains("Removed · 1"))
        XCTAssertTrue(output.contains("reclaimed (logical)"))
        XCTAssertTrue(output.contains("Removed.app"))
        XCTAssertTrue(output.contains("Failed · 1"))
        XCTAssertTrue(output.contains("simulated failure"))
        XCTAssertTrue(output.contains("Volume free:"))
        XCTAssertFalse(output.contains("\u{001B}"))
    }
}
