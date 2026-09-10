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
        defaultVolume: StatusDefaultVolume? = nil,
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
            defaultVolume: defaultVolume,
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

    func testDisplayWidthCalculation() {
        // ASCII
        XCTAssertEqual(OutputFormatter.displayWidth(of: "Hello World"), 11)
        XCTAssertEqual(OutputFormatter.displayWidth(of: ""), 0)

        // Korean (Hangul Syllables: width 2 each)
        // "카카오톡.app": 4 * 2 + 4 = 12
        XCTAssertEqual(OutputFormatter.displayWidth(of: "카카오톡.app"), 12)

        // Japanese (Kanji + Katakana / Hiragana: width 2 each)
        // "日本語.app": 3 * 2 + 4 = 10
        XCTAssertEqual(OutputFormatter.displayWidth(of: "日本語.app"), 10)

        // Chinese (Unified Ideographs: width 2 each)
        // "微信.app": 2 * 2 + 4 = 8
        XCTAssertEqual(OutputFormatter.displayWidth(of: "微信.app"), 8)

        // Emoji (width 2 each)
        // "🚀.app": 2 + 4 = 6
        XCTAssertEqual(OutputFormatter.displayWidth(of: "🚀.app"), 6)

        // ANSI escape codes should be ignored (width 0)
        XCTAssertEqual(OutputFormatter.displayWidth(of: "\u{001B}[1;36mSafe\u{001B}[0m"), 4)
        XCTAssertEqual(OutputFormatter.displayWidth(of: "\u{001B}[90m   path\u{001B}[0m"), 7)

        // Control characters should be ignored
        XCTAssertEqual(OutputFormatter.displayWidth(of: "\u{0007}text\u{001B}"), 4)
    }

    func testTerminalWidthDetection() {
        // Explicit COLUMNS environment variable
        XCTAssertEqual(OutputFormatter.terminalWidth(isTTY: false, environment: ["COLUMNS": "120"]), 120)
        XCTAssertEqual(OutputFormatter.terminalWidth(isTTY: true, environment: ["COLUMNS": "40"]), 40)

        // Non-TTY with no or invalid COLUMNS should default to 80
        XCTAssertEqual(OutputFormatter.terminalWidth(isTTY: false, environment: [:]), 80)
        XCTAssertEqual(OutputFormatter.terminalWidth(isTTY: false, environment: ["COLUMNS": "-5"]), 80)
        XCTAssertEqual(OutputFormatter.terminalWidth(isTTY: false, environment: ["COLUMNS": "abc"]), 80)
    }

    func testScanEmptyState() {
        let formatter = OutputFormatter(useColor: false)
        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [],
            externalApplications: [],
            unresolvedApplicationLinks: [],
            warnings: []
        )

        let output = formatter.scan(report)
        XCTAssertTrue(output.contains("MacBay scan"))
        XCTAssertTrue(output.contains("0 apps · 0 caches · 0 external"))
        XCTAssertTrue(output.contains("App threshold: 200.0 MB"))
        XCTAssertTrue(output.contains("No relocation candidates or external applications found."))
        XCTAssertFalse(output.contains("Applications ·"))
        XCTAssertFalse(output.contains("Developer caches ·"))
        XCTAssertFalse(output.contains("Already external ·"))
    }

    func testScanDefaultLayoutAndAlignment() {
        let formatter = OutputFormatter(useColor: false)
        let app1 = AppCandidate(
            name: "Aside.app",
            path: "/Applications/Aside.app",
            sizeBytes: 2_147_483_648, // 2.0 GB
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .popupRisk, reasons: ["Accessibility helper detected"])
        )
        let app2 = AppCandidate(
            name: "Claude.app",
            path: "/Applications/Claude.app",
            sizeBytes: 865_278_361, // 825.2 MB
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .blocked, reasons: ["System extension"])
        )
        let app3 = AppCandidate(
            name: "Antigravity.app",
            path: "/Applications/Antigravity.app",
            sizeBytes: 456_555_724, // 435.4 MB
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .safe, reasons: [])
        )
        let cache = AppCandidate(
            name: "CoreSimulator",
            path: "/Users/test/Library/Developer/CoreSimulator",
            sizeBytes: 200_802_304, // 191.5 MB
            kind: .developerCache,
            compatibility: nil
        )
        let ext = ExternalApplication(
            name: "ChatGPT.app",
            sourcePath: "/Applications/ChatGPT.app",
            destinationPath: "/Volumes/KLEVV/Applications/ChatGPT.app",
            sizeBytes: 1_395_864_371, // 1.3 GB
            managementStatus: .unmanaged
        )

        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [app1, app2, app3, cache],
            externalApplications: [ext],
            unresolvedApplicationLinks: [],
            warnings: []
        )

        let output = formatter.scan(report, terminalWidth: 80)

        // Summary header
        XCTAssertTrue(output.contains("MacBay scan"))
        XCTAssertTrue(output.contains("3 apps · 1 cache · 1 external"))
        XCTAssertTrue(output.contains("App threshold: 200.0 MB"))

        // Applications section
        XCTAssertTrue(output.contains("Applications · 3"))
        XCTAssertTrue(output.contains("NAME"))
        XCTAssertTrue(output.contains("SIZE"))
        XCTAssertTrue(output.contains("STATUS"))
        XCTAssertTrue(output.contains("Aside.app"))
        XCTAssertTrue(output.contains("Review"))
        XCTAssertTrue(output.contains("Claude.app"))
        XCTAssertTrue(output.contains("Blocked"))
        XCTAssertTrue(output.contains("Antigravity.app"))
        XCTAssertTrue(output.contains("Safe"))

        // Legends
        XCTAssertTrue(output.contains("Safe: no relocation signals detected"))
        XCTAssertTrue(output.contains("Review: check compatibility details before using --force"))
        XCTAssertTrue(output.contains("Blocked: migration not allowed"))

        // Developer caches section
        XCTAssertTrue(output.contains("Developer caches · 1"))
        XCTAssertTrue(output.contains("CoreSimulator"))
        XCTAssertTrue(output.contains("191.5 MB"))

        // Already external section
        XCTAssertTrue(output.contains("Already external · 1"))
        XCTAssertTrue(output.contains("ChatGPT.app"))
        XCTAssertTrue(output.contains("1.3 GB"))
        XCTAssertTrue(output.contains("Unmanaged"))
        XCTAssertTrue(output.contains("Unmanaged: no matching MacBay migration record"))
    }

    func testScanNarrowTerminalWrapping() {
        let formatter = OutputFormatter(useColor: false)
        let longName = "VeryLongAppNameExceedingNarrowTerminalLimit.app"
        let app = AppCandidate(
            name: longName,
            path: "/Applications/\(longName)",
            sizeBytes: 1_073_741_824, // 1.0 GB
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .safe, reasons: [])
        )
        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [app],
            externalApplications: [],
            unresolvedApplicationLinks: [],
            warnings: []
        )

        let output = formatter.scan(report, terminalWidth: 40)
        XCTAssertTrue(output.contains("  \(longName)\n    1.0 GB  Safe"))
        // Name should never be truncated
        XCTAssertTrue(output.contains(longName))
    }

    func testScanVerboseMode() {
        let formatter = OutputFormatter(useColor: false)
        let app = AppCandidate(
            name: "Aside.app",
            path: "/Applications/Aside.app",
            sizeBytes: 2_147_483_648,
            kind: .application,
            compatibility: CompatibilityAssessment(
                grade: .popupRisk,
                reasons: ["Contains LaunchAgent"],
                evidence: ["com.example.aside.plist"]
            )
        )
        let cache = AppCandidate(
            name: "npm cache",
            path: "/Users/test/.npm",
            sizeBytes: 130_245_000,
            kind: .developerCache,
            compatibility: nil
        )
        let ext = ExternalApplication(
            name: "ChatGPT.app",
            sourcePath: "/Applications/ChatGPT.app",
            destinationPath: "/Volumes/KLEVV/Applications/ChatGPT.app",
            sizeBytes: 1_000_000_000,
            managementStatus: .macBay
        )
        let link = UnresolvedApplicationLink(
            name: "DeadLink.app",
            sourcePath: "/Applications/DeadLink.app",
            destinationPath: "/Volumes/Gone/DeadLink.app",
            reason: "Target unavailable"
        )
        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [app, cache],
            externalApplications: [ext],
            unresolvedApplicationLinks: [link],
            warnings: []
        )

        let normalOutput = formatter.scan(report, verbose: false)
        XCTAssertFalse(normalOutput.contains("• Contains LaunchAgent"))
        XCTAssertFalse(normalOutput.contains("Evidence: com.example.aside.plist"))
        XCTAssertFalse(normalOutput.contains("    /Users/test/.npm"))
        XCTAssertFalse(normalOutput.contains("    /Applications/ChatGPT.app"))
        XCTAssertFalse(normalOutput.contains("    /Applications/DeadLink.app"))

        let verboseOutput = formatter.scan(report, verbose: true)
        XCTAssertTrue(verboseOutput.contains("• Contains LaunchAgent"))
        XCTAssertTrue(verboseOutput.contains("Evidence: com.example.aside.plist"))
        XCTAssertTrue(verboseOutput.contains("    /Users/test/.npm"))
        XCTAssertTrue(verboseOutput.contains("    /Applications/ChatGPT.app"))
        XCTAssertTrue(verboseOutput.contains("    /Applications/DeadLink.app"))
    }

    func testScanNoColorProducesNoAnsi() {
        let formatter = OutputFormatter(useColor: false)
        let app = AppCandidate(
            name: "Aside.app",
            path: "/Applications/Aside.app",
            sizeBytes: 2_147_483_648,
            kind: .application,
            compatibility: CompatibilityAssessment(grade: .popupRisk, reasons: ["Risk"])
        )
        let ext = ExternalApplication(
            name: "Ext.app",
            sourcePath: "/Applications/Ext.app",
            destinationPath: "/Volumes/Ext/Ext.app",
            sizeBytes: 100,
            managementStatus: .macBay
        )
        let link = UnresolvedApplicationLink(
            name: "Link.app",
            sourcePath: "/Applications/Link.app",
            destinationPath: "/Volumes/Gone/Link.app",
            reason: "Target unavailable"
        )
        let report = ScanReport(
            generatedAt: "2026-09-10T12:00:00Z",
            minimumApplicationSizeBytes: 200 * 1024 * 1024,
            candidates: [app],
            externalApplications: [ext],
            unresolvedApplicationLinks: [link],
            warnings: ["A warning"]
        )

        let output = formatter.scan(report, verbose: true)
        XCTAssertFalse(output.contains("\u{001B}"))
    }

    private func makeDoctorReport(
        volumes: [DoctorVolumeScope] = [],
        findings: [DoctorFinding] = [],
        warnings: [String] = []
    ) -> DoctorReport {
        DoctorReport(
            generatedAt: "2026-09-10T12:00:00Z",
            volumes: volumes,
            findings: findings,
            summary: DoctorSummary(
                checked: findings.count,
                healthy: findings.filter { $0.status == .healthy }.count,
                unmanaged: findings.filter { $0.status == .healthy && $0.managed == false }.count,
                needsAttention: findings.filter { $0.status == .needsAttention }.count,
                unableToVerify: findings.filter { $0.status == .unableToVerify }.count
            ),
            warnings: warnings
        )
    }

    func testDoctorRendersSections() {
        let formatter = OutputFormatter(useColor: false)
        let scope = DoctorVolumeScope(
            name: "ExternalSSD",
            mountPoint: "/Volumes/ExternalSSD",
            manifestPath: "/Volumes/ExternalSSD/MacBay/manifest.json",
            isReadOnly: false,
            manifestStatus: .loaded,
            recordCount: 2
        )
        let report = makeDoctorReport(
            volumes: [scope],
            findings: [
                DoctorFinding(
                    code: .linkTargetUnavailable,
                    status: .needsAttention,
                    category: .applicationLink,
                    name: "Offline.app",
                    paths: ["/Applications/Offline.app", "/Volumes/Gone/Offline.app"],
                    detail: "Target unavailable: /Volumes/Gone/Offline.app",
                    recommendation: "Reconnect the volume or confirm the path exists, then run 'mb doctor' again."
                ),
                DoctorFinding(
                    code: .manifestUnreadable,
                    status: .unableToVerify,
                    category: .volume,
                    name: "ExternalSSD",
                    paths: ["/Volumes/ExternalSSD/MacBay/manifest.json"],
                    detail: "Manifest could not be read: data is corrupted",
                    recommendation: "Inspect or restore the manifest."
                ),
                DoctorFinding(
                    code: .linkManagedRecord,
                    status: .healthy,
                    category: .applicationLink,
                    name: "Aside.app",
                    paths: ["/Applications/Aside.app", "/Volumes/ExternalSSD/MacBay/Applications/Aside.app"],
                    detail: "Managed by MacBay, record matches",
                    recommendation: "",
                    managed: true
                ),
                DoctorFinding(
                    code: .linkUnmanaged,
                    status: .healthy,
                    category: .applicationLink,
                    name: "ChatGPT.app",
                    paths: ["/Applications/ChatGPT.app", "/Volumes/ExternalSSD/Manual/ChatGPT.app"],
                    detail: "No MacBay record for this link",
                    recommendation: "",
                    managed: false
                )
            ],
            warnings: ["A warning"]
        )

        let output = formatter.doctor(report)

        XCTAssertTrue(output.contains("MacBay doctor"))
        XCTAssertTrue(output.contains("Volumes consulted · 1"))
        XCTAssertTrue(output.contains("ExternalSSD (/Volumes/ExternalSSD) — 2 records"))
        XCTAssertTrue(output.contains("Needs attention · 1"))
        XCTAssertTrue(output.contains("Unable to verify · 1"))
        XCTAssertTrue(output.contains("Healthy · 2"))
        XCTAssertTrue(output.contains("Next: Reconnect the volume"))
        XCTAssertTrue(output.contains("[MacBay]"))
        XCTAssertTrue(output.contains("[unmanaged]"))
        XCTAssertTrue(output.contains("Warnings · 1"))
    }

    func testDoctorRendersReadOnlyAndEmptyScope() {
        let formatter = OutputFormatter(useColor: false)
        let scope = DoctorVolumeScope(
            name: "Archive",
            mountPoint: "/Volumes/Archive",
            manifestPath: "/Volumes/Archive/MacBay/manifest.json",
            isReadOnly: true,
            manifestStatus: .missing,
            recordCount: 0
        )

        let output = formatter.doctor(makeDoctorReport(volumes: [scope]))

        XCTAssertTrue(output.contains("Archive (/Volumes/Archive) — no MacBay records (read-only)"))
        XCTAssertTrue(output.contains("Nothing to verify"))
        XCTAssertTrue(output.contains("No MacBay records and no relocated links were found"))
    }

    func testDoctorWithColorDisabledHasNoAnsi() {
        let formatter = OutputFormatter(useColor: false)
        let finding = DoctorFinding(
            code: .linkCircular,
            status: .needsAttention,
            category: .applicationLink,
            name: "Loop.app",
            paths: ["/Applications/Loop.app", "/Applications/Loop.app"],
            detail: "Circular link detected: /Applications/Loop.app",
            recommendation: "Repoint the link to the external copy or remove it manually."
        )

        let output = formatter.doctor(makeDoctorReport(findings: [finding], warnings: ["warning"]))

        XCTAssertFalse(output.contains("\u{001B}"))
        XCTAssertEqual(makeDoctorReport(findings: [finding]).exitCode, 1)
        XCTAssertEqual(makeDoctorReport().exitCode, 0)
    }

    func testStatusShowsDefaultVolumeGroup() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport(defaultVolume: StatusDefaultVolume(
            name: "ExternalSSD",
            path: "/Volumes/ExternalSSD",
            uuid: "UUID-SSD",
            mountedPath: "/Volumes/ExternalSSD"
        ))

        let output = formatter.status(report)

        XCTAssertTrue(output.contains("Default volume · ExternalSSD"))
        XCTAssertTrue(output.contains("  /Volumes/ExternalSSD"))
        XCTAssertFalse(output.contains("Mounted at"))
        XCTAssertFalse(output.contains("None (run 'mb init')"))
    }

    func testStatusShowsMovedDefaultVolumeMountPoint() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport(defaultVolume: StatusDefaultVolume(
            name: "ExternalSSD",
            path: "/Volumes/ExternalSSD",
            mountedPath: "/Volumes/ExternalSSD 1"
        ))

        let output = formatter.status(report)

        XCTAssertTrue(output.contains("Default volume · ExternalSSD"))
        XCTAssertTrue(output.contains("  Mounted at /Volumes/ExternalSSD 1"))
    }

    func testStatusShowsUnavailableDefaultVolume() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport(defaultVolume: StatusDefaultVolume(
            name: "OfflineSSD",
            path: "/Volumes/OfflineSSD"
        ))

        let output = formatter.status(report)

        XCTAssertTrue(output.contains("Default volume · OfflineSSD"))
        XCTAssertTrue(output.contains("  /Volumes/OfflineSSD"))
        XCTAssertFalse(output.contains("Mounted at"))
    }

    func testStatusWithoutDefaultVolumeSuggestsInit() {
        let formatter = OutputFormatter(useColor: false)

        let output = formatter.status(makeReport())

        XCTAssertTrue(output.contains("Default volume · none"))
        XCTAssertTrue(output.contains("  None (run 'mb init')"))
    }

    func testInitReportRendersSavedVolume() {
        let formatter = OutputFormatter(useColor: false)
        let report = InitReport(
            volume: sampleVolume(totalBytes: 1_000, availableBytes: 500),
            configPath: "/Users/test/.config/macbay/config.json",
            replaced: false
        )

        let output = formatter.initReport(report)

        XCTAssertTrue(output.contains("MacBay default volume"))
        XCTAssertTrue(output.contains("  Saved: TestVolume (/Volumes/TestVolume)"))
        XCTAssertTrue(output.contains("  Configuration: /Users/test/.config/macbay/config.json"))
        XCTAssertFalse(output.contains("Previous:"))
        XCTAssertFalse(output.contains("\u{001B}"))
    }

    func testInitReportShowsReplacedDefault() {
        let formatter = OutputFormatter(useColor: false)
        let report = InitReport(
            volume: sampleVolume(totalBytes: 1_000, availableBytes: 500),
            configPath: "/Users/test/.config/macbay/config.json",
            previousDefault: DefaultVolume(
                path: "/Volumes/OldSSD",
                name: "OldSSD",
                savedAt: "2026-09-01T12:00:00Z"
            ),
            replaced: true
        )

        let output = formatter.initReport(report)

        XCTAssertTrue(output.contains("  Previous: OldSSD (/Volumes/OldSSD)"))
    }

    func testConfigReportRendersSavedAndRemovedDefaults() {
        let formatter = OutputFormatter(useColor: false)
        let entry = DefaultVolume(
            path: "/Volumes/ExternalSSD",
            name: "ExternalSSD",
            uuid: "UUID-SSD",
            savedAt: "2026-09-10T12:00:00Z"
        )

        let showOutput = formatter.configReport(ConfigReport(
            configPath: "/Users/test/.config/macbay/config.json",
            defaultVolume: entry
        ))
        XCTAssertTrue(showOutput.contains("MacBay configuration"))
        XCTAssertTrue(showOutput.contains("  Configuration: /Users/test/.config/macbay/config.json"))
        XCTAssertTrue(showOutput.contains("  Default volume: ExternalSSD (/Volumes/ExternalSSD)"))
        XCTAssertTrue(showOutput.contains("  UUID: UUID-SSD"))
        XCTAssertFalse(showOutput.contains("Removed default volume"))

        let resetOutput = formatter.configReport(ConfigReport(
            configPath: "/Users/test/.config/macbay/config.json",
            removedVolume: entry
        ))
        XCTAssertTrue(resetOutput.contains("  Removed default volume: ExternalSSD (/Volumes/ExternalSSD)"))
        XCTAssertTrue(resetOutput.contains("  Default volume: None (run 'mb init')"))
    }

    func testStatusWithColorDisabledHasNoAnsiForDefaultVolume() {
        let formatter = OutputFormatter(useColor: false)
        let report = makeReport(defaultVolume: StatusDefaultVolume(
            name: "ExternalSSD",
            path: "/Volumes/ExternalSSD",
            mountedPath: "/Volumes/ExternalSSD"
        ))

        XCTAssertFalse(formatter.status(report).contains("\u{001B}"))
    }
}
