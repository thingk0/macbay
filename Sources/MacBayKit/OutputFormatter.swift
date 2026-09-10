import Foundation

import Darwin

public struct OutputFormatter {
    public let useColor: Bool

    public init(useColor: Bool = true) {
        self.useColor = useColor
    }

    public static func isColorSupported(
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isTTY else { return false }
        guard environment["NO_COLOR"] == nil else { return false }
        guard environment["TERM"] != "dumb" else { return false }
        return true
    }

    public func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public func status(_ report: StatusReport) -> String {
        var groups: [[String]] = []

        groups.append([style("MacBay storage status", color: "36", bold: true)])
        groups.append(formatVolume(label: "Internal", volume: report.internalVolume))

        if report.externalVolumes.isEmpty {
            groups.append([
                style("External volumes · 0", color: "33"),
                "  None detected"
            ])
        } else {
            for volume in report.externalVolumes {
                groups.append(formatVolume(label: "External", volume: volume))
            }
        }

        var dockedLines = ["Docked items · \(report.dockedItems.count)"]
        if report.dockedItems.isEmpty {
            dockedLines.append("  None")
        } else {
            for item in report.dockedItems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                dockedLines.append("  • \(item.name) — \(Self.humanBytes(item.sizeBytes)) (\(item.externalPath))")
            }
        }
        groups.append(dockedLines)

        if !report.warnings.isEmpty {
            var warningLines = ["Warnings · \(report.warnings.count)"]
            for warning in report.warnings {
                warningLines.append("  • \(warning)")
            }
            groups.append(warningLines)
        }

        return groups.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private func formatVolume(label: String, volume: StorageVolume) -> [String] {
        var lines = [
            "\(label) · \(volume.name)",
            "  \(volume.path)"
        ]

        let total = volume.totalBytes
        let available = min(volume.availableBytes, total)
        let used = total - available

        if total == 0 {
            lines.append("  Capacity unavailable")
        } else {
            let ratio = Double(used) / Double(total)
            let percentage = ratio * 100.0
            let filledBlocks = min(max(Int((ratio * 20.0).rounded()), 0), 20)
            let emptyBlocks = 20 - filledBlocks
            let bar = String(repeating: "█", count: filledBlocks) + String(repeating: "░", count: emptyBlocks)

            let color: String
            if percentage < 80.0 {
                color = "36"
            } else if percentage < 90.0 {
                color = "33"
            } else {
                color = "31"
            }

            let styledBar = style(bar, color: color)
            let percentString = String(format: "%.1f%% used", percentage)
            lines.append("  \(styledBar)  \(percentString)")
        }

        lines.append("  Used: \(Self.humanBytes(used)) / \(Self.humanBytes(total))")
        lines.append("  Free: \(Self.humanBytes(available))")
        return lines
    }

    public func scan(
        _ report: ScanReport,
        verbose: Bool = false,
        terminalWidth: Int? = nil
    ) -> String {
        let termWidth = terminalWidth ?? Self.terminalWidth()

        let apps = report.candidates.filter { $0.kind == .application }
        let caches = report.candidates.filter { $0.kind == .developerCache }
        let external = report.externalApplications
        let unresolved = report.unresolvedApplicationLinks
        let warnings = report.warnings

        let isEmpty = apps.isEmpty && caches.isEmpty && external.isEmpty && unresolved.isEmpty && warnings.isEmpty

        var sections: [[String]] = []

        let appCount = apps.count
        let cacheCount = caches.count
        let extCount = external.count

        let appWord = appCount == 1 ? "app" : "apps"
        let cacheWord = cacheCount == 1 ? "cache" : "caches"
        let summaryLine = "\(appCount) \(appWord) · \(cacheCount) \(cacheWord) · \(extCount) external"

        let headerLines = [
            style("MacBay scan", color: "36", bold: true),
            summaryLine,
            "App threshold: \(Self.humanBytes(report.minimumApplicationSizeBytes))"
        ]
        sections.append(headerLines)

        if isEmpty {
            sections.append(["No relocation candidates or external applications found."])
            return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        }

        // 1. Applications section
        if !apps.isEmpty {
            var appLines = [bold("Applications · \(appCount)")]

            struct AppRow {
                let candidate: AppCandidate
                let name: String
                let sizeString: String
                let statusText: String
                let statusColor: String
            }

            let appRows: [AppRow] = apps.map { app in
                let statusText: String
                let statusColor: String
                switch app.compatibility?.grade {
                case .safe:
                    statusText = "Safe"
                    statusColor = "36"
                case .popupRisk:
                    statusText = "Review"
                    statusColor = "33"
                case .blocked:
                    statusText = "Blocked"
                    statusColor = "31"
                case .none:
                    statusText = "Unknown"
                    statusColor = "90"
                }
                return AppRow(
                    candidate: app,
                    name: app.name,
                    sizeString: Self.humanBytes(app.sizeBytes),
                    statusText: statusText,
                    statusColor: statusColor
                )
            }

            let maxSizeWidth = max(appRows.map { Self.displayWidth(of: $0.sizeString) }.max() ?? 4, 4)
            let maxStatusWidth = max(appRows.map { Self.displayWidth(of: $0.statusText) }.max() ?? 6, 6)
            let fixedColumnsWidth = 2 + 2 + maxSizeWidth + 2 + maxStatusWidth
            let maxAllowedNameWidth = termWidth - fixedColumnsWidth

            let fittingRows = appRows.filter { Self.displayWidth(of: $0.name) <= maxAllowedNameWidth }
            let nameColWidth = max(fittingRows.map { Self.displayWidth(of: $0.name) }.max() ?? 4, 4)

            if maxAllowedNameWidth >= 4 && !fittingRows.isEmpty {
                let h1 = "  " + padRight("NAME", rawText: "NAME", toDisplayWidth: nameColWidth)
                let h2 = "  " + padLeft("SIZE", rawText: "SIZE", toDisplayWidth: maxSizeWidth)
                let h3 = "  STATUS"
                appLines.append(dim(h1 + h2 + h3))
            }

            for row in appRows {
                let nameWidth = Self.displayWidth(of: row.name)
                let styledName = bold(row.name)
                let styledStatus = style(row.statusText, color: row.statusColor)

                if nameWidth <= maxAllowedNameWidth {
                    let c1 = "  " + padRight(styledName, rawText: row.name, toDisplayWidth: nameColWidth)
                    let c2 = "  " + padLeft(row.sizeString, rawText: row.sizeString, toDisplayWidth: maxSizeWidth)
                    let c3 = "  " + styledStatus
                    appLines.append(c1 + c2 + c3)
                } else {
                    appLines.append("  " + styledName)
                    appLines.append("    " + padLeft(row.sizeString, rawText: row.sizeString, toDisplayWidth: maxSizeWidth) + "  " + styledStatus)
                }

                if verbose {
                    appLines.append("    " + dim(row.candidate.path))
                    if let assessment = row.candidate.compatibility {
                        for reason in assessment.reasons {
                            appLines.append("    • " + dim(reason))
                        }
                        for evidence in assessment.evidence {
                            appLines.append("      " + dim("Evidence: \(evidence)"))
                        }
                    }
                }
            }

            var legendLines: [String] = []
            let hasSafe = apps.contains { $0.compatibility?.grade == .safe }
            let hasReview = apps.contains { $0.compatibility?.grade == .popupRisk }
            let hasBlocked = apps.contains { $0.compatibility?.grade == .blocked }

            if hasSafe {
                legendLines.append("  " + style("Safe", color: "36") + dim(": no relocation signals detected"))
            }
            if hasReview {
                legendLines.append("  " + style("Review", color: "33") + dim(": check compatibility details before using --force"))
            }
            if hasBlocked {
                legendLines.append("  " + style("Blocked", color: "31") + dim(": migration not allowed"))
            }

            if !legendLines.isEmpty {
                appLines.append("")
                appLines.append(contentsOf: legendLines)
            }

            sections.append(appLines)
        }

        // 2. Developer caches section
        if !caches.isEmpty {
            var cacheLines = [bold("Developer caches · \(cacheCount)")]

            let cacheSizes = caches.map { (cache: $0, sizeString: Self.humanBytes($0.sizeBytes)) }
            let maxSizeWidth = max(cacheSizes.map { Self.displayWidth(of: $0.sizeString) }.max() ?? 4, 4)
            let fixedColumnsWidth = 2 + 2 + maxSizeWidth
            let maxAllowedNameWidth = termWidth - fixedColumnsWidth

            let fittingCaches = cacheSizes.filter { Self.displayWidth(of: $0.cache.name) <= maxAllowedNameWidth }
            let nameColWidth = max(fittingCaches.map { Self.displayWidth(of: $0.cache.name) }.max() ?? 4, 4)

            for item in cacheSizes {
                let nameWidth = Self.displayWidth(of: item.cache.name)
                let styledName = bold(item.cache.name)

                if nameWidth <= maxAllowedNameWidth {
                    let c1 = "  " + padRight(styledName, rawText: item.cache.name, toDisplayWidth: nameColWidth)
                    let c2 = "  " + padLeft(item.sizeString, rawText: item.sizeString, toDisplayWidth: maxSizeWidth)
                    cacheLines.append(c1 + c2)
                } else {
                    cacheLines.append("  " + styledName)
                    cacheLines.append("    " + padLeft(item.sizeString, rawText: item.sizeString, toDisplayWidth: maxSizeWidth))
                }

                if verbose {
                    cacheLines.append("    " + dim(item.cache.path))
                }
            }

            sections.append(cacheLines)
        }

        // 3. Already external section
        if !external.isEmpty {
            var extLines = [bold("Already external · \(extCount)")]

            struct ExtRow {
                let app: ExternalApplication
                let name: String
                let sizeString: String
                let statusText: String
                let statusColor: String
            }

            let extRows: [ExtRow] = external.map { app in
                let statusText: String
                let statusColor: String
                switch app.managementStatus {
                case .macBay:
                    statusText = "MacBay"
                    statusColor = "36"
                case .unmanaged:
                    statusText = "Unmanaged"
                    statusColor = "33"
                case .unconfirmed:
                    statusText = "Unconfirmed"
                    statusColor = "31"
                }
                let sizeStr = app.sizeBytes.map { Self.humanBytes($0) } ?? "Unknown"
                return ExtRow(
                    app: app,
                    name: app.name,
                    sizeString: sizeStr,
                    statusText: statusText,
                    statusColor: statusColor
                )
            }

            let maxSizeWidth = max(extRows.map { Self.displayWidth(of: $0.sizeString) }.max() ?? 4, 4)
            let maxStatusWidth = max(extRows.map { Self.displayWidth(of: $0.statusText) }.max() ?? 6, 6)
            let fixedColumnsWidth = 2 + 2 + maxSizeWidth + 2 + maxStatusWidth
            let maxAllowedNameWidth = termWidth - fixedColumnsWidth

            let fittingRows = extRows.filter { Self.displayWidth(of: $0.name) <= maxAllowedNameWidth }
            let nameColWidth = max(fittingRows.map { Self.displayWidth(of: $0.name) }.max() ?? 4, 4)

            for row in extRows {
                let nameWidth = Self.displayWidth(of: row.name)
                let styledName = bold(row.name)
                let styledStatus = style(row.statusText, color: row.statusColor)

                if nameWidth <= maxAllowedNameWidth {
                    let c1 = "  " + padRight(styledName, rawText: row.name, toDisplayWidth: nameColWidth)
                    let c2 = "  " + padLeft(row.sizeString, rawText: row.sizeString, toDisplayWidth: maxSizeWidth)
                    let c3 = "  " + styledStatus
                    extLines.append(c1 + c2 + c3)
                } else {
                    extLines.append("  " + styledName)
                    extLines.append("    " + padLeft(row.sizeString, rawText: row.sizeString, toDisplayWidth: maxSizeWidth) + "  " + styledStatus)
                }

                if verbose {
                    extLines.append("    " + dim(row.app.sourcePath))
                }
                extLines.append("    → " + dim(row.app.destinationPath))
            }

            var legendLines: [String] = []
            let hasMacBay = external.contains { $0.managementStatus == .macBay }
            let hasUnmanaged = external.contains { $0.managementStatus == .unmanaged }
            let hasUnconfirmed = external.contains { $0.managementStatus == .unconfirmed }

            if hasMacBay {
                legendLines.append("  " + style("MacBay", color: "36") + dim(": recorded in volume manifest"))
            }
            if hasUnmanaged {
                legendLines.append("  " + style("Unmanaged", color: "33") + dim(": no matching MacBay migration record"))
            }
            if hasUnconfirmed {
                legendLines.append("  " + style("Unconfirmed", color: "31") + dim(": volume manifest read error"))
            }

            if !legendLines.isEmpty {
                extLines.append("")
                extLines.append(contentsOf: legendLines)
            }

            sections.append(extLines)
        }

        // 4. Unresolved links section
        if !unresolved.isEmpty {
            var unresolvedLines = [bold("Unresolved links · \(unresolved.count)")]
            for link in unresolved {
                unresolvedLines.append("  " + bold(link.name) + " — " + style(link.reason, color: "31"))
                if verbose {
                    unresolvedLines.append("    " + dim(link.sourcePath))
                }
                unresolvedLines.append("    → " + dim(link.destinationPath))
            }
            sections.append(unresolvedLines)
        }

        // 5. Warnings section
        if !warnings.isEmpty {
            var warningLines = [bold("Warnings · \(warnings.count)")]
            for warning in warnings {
                warningLines.append("  • " + warning)
            }
            sections.append(warningLines)
        }

        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    public func migration(_ result: MigrationResult) -> String {
        let prefix = result.dryRun ? "Dry run" : "Completed"
        return ([
            style("\(prefix): \(result.operation) \(result.name)", color: result.dryRun ? "33" : "32", bold: true),
            "  Size: \(Self.humanBytes(result.sizeBytes))",
            "  Source: \(result.sourcePath)",
            "  Destination: \(result.destinationPath)"
        ] + result.messages.map { "  \($0)" }).joined(separator: "\n")
    }

    public func xcode(_ report: XcodeDoctorReport) -> String {
        var lines = [style("MacBay Xcode doctor", color: "36", bold: true)]
        if let deviceSupport = report.deviceSupport {
            lines.append(migration(deviceSupport))
        } else {
            lines.append("iOS DeviceSupport: not present")
        }
        if let cleanup = report.simulatorCleanup {
            lines.append("Simulator cleanup: \(cleanup.succeeded ? "completed" : "failed")")
            if !cleanup.output.isEmpty {
                lines.append(cleanup.output)
            }
        }
        return lines.joined(separator: "\n")
    }

    public func cache(_ report: CacheReport) -> String {
        var lines = [style("MacBay cache configuration", color: "36", bold: true)]
        if report.reset {
            lines.append("Removed MacBay cache settings from \(report.shellConfigurationPath)")
        } else {
            lines.append("Cache routing: \(report.enabled ? "enabled" : "preview")")
            lines.append("Shell configuration: \(report.shellConfigurationPath)")
            lines.append(contentsOf: report.targets.map { migration($0) })
        }
        return lines.joined(separator: "\n")
    }

    public func doctor(_ report: DoctorReport) -> String {
        var sections: [[String]] = []

        sections.append([style("MacBay doctor", color: "36", bold: true)])

        var volumeLines = [bold("Volumes consulted · \(report.volumes.count)")]
        if report.volumes.isEmpty {
            volumeLines.append("  None detected")
        } else {
            for scope in report.volumes {
                volumeLines.append(
                    "  • " + bold(scope.name)
                        + dim(" (\(scope.mountPoint))")
                        + " — " + Self.manifestSummary(scope)
                )
            }
        }
        sections.append(volumeLines)

        let attention = report.findings.filter { $0.status == .needsAttention }
        let unverified = report.findings.filter { $0.status == .unableToVerify }
        let healthy = report.findings.filter { $0.status == .healthy }

        if report.findings.isEmpty {
            sections.append([
                bold("Nothing to verify"),
                "  " + dim("No MacBay records and no relocated links were found on the connected volumes.")
            ])
        } else {
            if !attention.isEmpty {
                sections.append(findingSection(title: "Needs attention", color: "31", findings: attention))
            }
            if !unverified.isEmpty {
                sections.append(findingSection(title: "Unable to verify", color: "33", findings: unverified))
            }
            if !healthy.isEmpty {
                sections.append(healthySection(healthy))
            }
        }

        if !report.warnings.isEmpty {
            var warningLines = [bold("Warnings · \(report.warnings.count)")]
            for warning in report.warnings {
                warningLines.append("  • " + warning)
            }
            sections.append(warningLines)
        }

        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private func findingSection(title: String, color: String, findings: [DoctorFinding]) -> [String] {
        var lines = [bold("\(title) · \(findings.count)")]
        for finding in findings {
            lines.append("  " + bold(finding.name) + " — " + style(finding.detail, color: color))
            if !finding.recommendation.isEmpty {
                lines.append("    " + dim("Next:") + " " + finding.recommendation)
            }
        }
        return lines
    }

    private func healthySection(_ findings: [DoctorFinding]) -> [String] {
        var lines = [bold("Healthy · \(findings.count)")]
        for finding in findings {
            var line = "  • " + bold(finding.name)
            if finding.paths.count > 1 {
                line += " → " + dim(finding.paths[1])
            }
            let tag = Self.managementTag(for: finding)
            if !tag.isEmpty {
                line += " " + style(tag, color: finding.managed == true ? "36" : "33")
            }
            lines.append(line)
        }
        return lines
    }

    private static func managementTag(for finding: DoctorFinding) -> String {
        switch finding.code {
        case .linkManagedRecord: return "[MacBay]"
        case .linkManagedLayout: return "[layout]"
        case .linkUnmanaged: return "[unmanaged]"
        default: return ""
        }
    }

    private static func manifestSummary(_ scope: DoctorVolumeScope) -> String {
        var summary: String
        switch scope.manifestStatus {
        case .loaded:
            summary = scope.recordCount == 1 ? "1 record" : "\(scope.recordCount) records"
        case .missing:
            summary = "no MacBay records"
        case .unreadable:
            summary = "records unreadable"
        case .unsupportedVersion:
            summary = "records use an unsupported version"
        }
        if scope.isReadOnly {
            summary += " (read-only)"
        }
        return summary
    }

    public static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    static func humanSignedBytes(_ bytes: Int64) -> String {
        guard bytes < 0 else { return humanBytes(UInt64(bytes)) }
        return "-" + humanBytes(bytes.magnitude)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func style(_ value: String, color: String, bold: Bool = false) -> String {
        guard useColor else { return value }
        let emphasis = bold ? "1;" : ""
        return "\u{001B}[\(emphasis)\(color)m\(value)\u{001B}[0m"
    }

    private func bold(_ value: String) -> String {
        guard useColor else { return value }
        return "\u{001B}[1m\(value)\u{001B}[0m"
    }

    private func dim(_ value: String) -> String {
        guard useColor else { return value }
        return "\u{001B}[90m\(value)\u{001B}[0m"
    }

    private func padRight(_ styledText: String, rawText: String, toDisplayWidth: Int) -> String {
        let width = Self.displayWidth(of: rawText)
        let pad = max(toDisplayWidth - width, 0)
        return styledText + String(repeating: " ", count: pad)
    }

    private func padLeft(_ styledText: String, rawText: String, toDisplayWidth: Int) -> String {
        let width = Self.displayWidth(of: rawText)
        let pad = max(toDisplayWidth - width, 0)
        return String(repeating: " ", count: pad) + styledText
    }

    public static func displayWidth(of text: String) -> Int {
        let stripped: String
        if text.contains("\u{001B}") {
            stripped = text.replacingOccurrences(
                of: "\u{001B}\\[[0-9;]*[a-zA-Z]",
                with: "",
                options: .regularExpression
            )
        } else {
            stripped = text
        }

        var width = 0
        for scalar in stripped.unicodeScalars {
            let val = scalar.value
            if (val >= 0 && val <= 31) || (val >= 127 && val <= 159) {
                continue
            }
            if (val >= 0x0300 && val <= 0x036F) ||
               (val >= 0x1AB0 && val <= 0x1AFF) ||
               (val >= 0x1DC0 && val <= 0x1DFF) ||
               (val >= 0x200B && val <= 0x200F) ||
               (val >= 0x202A && val <= 0x202E) ||
               (val >= 0x2060 && val <= 0x206F) ||
               (val >= 0xFE00 && val <= 0xFE0F) ||
               (val >= 0xFEFF && val <= 0xFEFF) ||
               (val >= 0xE0100 && val <= 0xE01EF) {
                continue
            }
            if isWide(val) {
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }

    private static func isWide(_ val: UInt32) -> Bool {
        if (val >= 0x1100 && val <= 0x115F) ||
           (val >= 0x11A3 && val <= 0x11A7) ||
           (val >= 0x11FA && val <= 0x11FF) {
            return true
        }
        if (val >= 0x2E80 && val <= 0x2FD5) || (val >= 0x2FF0 && val <= 0x2FFF) {
            return true
        }
        if val >= 0x3000 && val <= 0x33FF {
            return true
        }
        if val >= 0x3400 && val <= 0x4DBF {
            return true
        }
        if val >= 0x4E00 && val <= 0x9FFF {
            return true
        }
        if val >= 0xA000 && val <= 0xA4CF {
            return true
        }
        if val >= 0xAC00 && val <= 0xD7AF {
            return true
        }
        if val >= 0xF900 && val <= 0xFAFF {
            return true
        }
        if val >= 0xFE30 && val <= 0xFE4F {
            return true
        }
        if (val >= 0xFF01 && val <= 0xFF60) || (val >= 0xFFE0 && val <= 0xFFE6) {
            return true
        }
        if val >= 0x2600 && val <= 0x27BF {
            return true
        }
        if val >= 0x2B00 && val <= 0x2BFF {
            return true
        }
        if val >= 0x20000 && val <= 0x2FA1F {
            return true
        }
        if val >= 0x1F000 && val <= 0x1FAFF {
            return true
        }
        return false
    }

    public static func terminalWidth(
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        fileDescriptor: Int32 = STDOUT_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let envCols = environment["COLUMNS"], let cols = Int(envCols), cols > 0 {
            return cols
        }
        if isTTY {
            var w = winsize()
            if ioctl(fileDescriptor, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 {
                return Int(w.ws_col)
            }
        }
        return 80
    }
}
