import Foundation

public struct OutputFormatter {
    public let useColor: Bool

    public init(useColor: Bool = true) {
        self.useColor = useColor
    }

    public func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public func status(_ report: StatusReport) -> String {
        var lines = [
            style("MacBay storage status", color: "36", bold: true),
            "Internal: \(report.internalVolume.name) (\(report.internalVolume.path))",
            "  Free: \(Self.humanBytes(report.internalVolume.availableBytes)) / \(Self.humanBytes(report.internalVolume.totalBytes)) (\(Self.percent(report.internalVolume.availablePercentage)) available)"
        ]

        if report.externalVolumes.isEmpty {
            lines.append(style("External volumes: none detected", color: "33"))
        } else {
            lines.append("External volumes:")
            for volume in report.externalVolumes {
                lines.append(
                    "  • \(volume.name) (\(volume.path)) — \(Self.humanBytes(volume.availableBytes)) free"
                )
            }
        }

        lines.append("Docked items:")
        if report.dockedItems.isEmpty {
            lines.append("  None")
        } else {
            for item in report.dockedItems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                lines.append("  • \(item.name) — \(Self.humanBytes(item.sizeBytes)) (\(item.externalPath))")
            }
        }
        if !report.warnings.isEmpty {
            lines.append("Warnings:")
            for warning in report.warnings {
                lines.append("  • \(warning)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func scan(_ report: ScanReport) -> String {
        var lines = [
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
            lines.append(
                "  • [\(label)]\(badge) \(candidate.name) — \(Self.humanBytes(candidate.sizeBytes)) (\(candidate.path))"
            )
        }
        if !report.warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: report.warnings.map { "  • \($0)" })
        }
        return lines.joined(separator: "\n")
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
