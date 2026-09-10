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

    public func scan(_ report: ScanReport) -> String {
        var sections: [[String]] = []

        var candidateLines = [
            style("MacBay scan", color: "36", bold: true),
            "Threshold: \(Self.humanBytes(report.minimumApplicationSizeBytes))",
            "Candidates: \(report.candidates.count)"
        ]
        for candidate in report.candidates {
            let label = candidate.kind == .application ? "app" : "cache"
            let badge: String
            switch candidate.compatibility?.grade {
            case .safe:
                badge = " 🟢 SAFE"
            case .popupRisk:
                badge = " ⚠️ POPUP_RISK"
            case .blocked:
                badge = " ❌ BLOCKED"
            case .none:
                badge = ""
            }
            candidateLines.append(
                "  • [\(label)]\(badge) \(candidate.name) — \(Self.humanBytes(candidate.sizeBytes)) (\(candidate.path))"
            )
        }
        sections.append(candidateLines)

        if !report.externalApplications.isEmpty {
            var externalLines = ["Already external · \(report.externalApplications.count)"]
            for (index, app) in report.externalApplications.enumerated() {
                if index > 0 {
                    externalLines.append("")
                }
                let sizeString = app.sizeBytes.map { Self.humanBytes($0) } ?? "Unknown"
                externalLines.append("  ↗ \(app.name) — \(sizeString) \(app.managementStatus.badge)")
                externalLines.append("    \(app.sourcePath)")
                externalLines.append("    → \(app.destinationPath)")
            }
            sections.append(externalLines)
        }

        if !report.unresolvedApplicationLinks.isEmpty {
            var unresolvedLines = ["Unresolved links · \(report.unresolvedApplicationLinks.count)"]
            for (index, link) in report.unresolvedApplicationLinks.enumerated() {
                if index > 0 {
                    unresolvedLines.append("")
                }
                unresolvedLines.append("  ? \(link.name) — \(link.reason)")
                unresolvedLines.append("    → \(link.destinationPath)")
            }
            sections.append(unresolvedLines)
        }

        if !report.warnings.isEmpty {
            var warningLines = ["Warnings:"]
            warningLines.append(contentsOf: report.warnings.map { "  • \($0)" })
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

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func style(_ value: String, color: String, bold: Bool = false) -> String {
        guard useColor else { return value }
        let emphasis = bold ? "1;" : ""
        return "\u{001B}[\(emphasis)\(color)m\(value)\u{001B}[0m"
    }
}
