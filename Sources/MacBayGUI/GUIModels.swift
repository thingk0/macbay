import Foundation
import MacBayKit

public enum GUISection: String, CaseIterable, Identifiable {
    case overview, applications, developer, cleanup, updates, recovery, diagnostics, history
    public var id: Self { self }
    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .applications: return "Applications"
        case .developer: return "Developer Data"
        case .cleanup: return "Cleanup"
        case .updates: return "Update Center"
        case .recovery: return "Recovery Center"
        case .diagnostics: return "Diagnostics"
        case .history: return "History"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .applications: return "app"
        case .developer: return "curlybraces"
        case .cleanup: return "sparkles"
        case .updates: return "arrow.triangle.2.circlepath"
        case .recovery: return "arrow.uturn.backward.circle"
        case .diagnostics: return "checkmark.shield"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

public enum GUIAppLocation: String, CaseIterable, Identifiable {
    case onMac = "On Mac", external = "External", all = "All"
    public var id: Self { self }
}

public struct GUIApplication: Equatable, Identifiable, Sendable {
    public enum State: String, Sendable {
        case ready = "Ready", review = "Review", blocked = "Blocked", external = "External"
        case unmanaged = "Unmanaged", unverified = "Unverified", unavailable = "Unavailable"
    }
    public let name: String
    public let path: String
    public let externalPath: String?
    public let sizeBytes: UInt64?
    public let state: State
    public let reasons: [String]
    public var id: String { path }
    public var displayName: String { (name as NSString).deletingPathExtension }
    public var isExternal: Bool { externalPath != nil }
    public var canPreview: Bool { [.ready, .review, .external].contains(state) }
    public var isRestore: Bool { state == .external }

    public init(name: String, path: String, externalPath: String? = nil, sizeBytes: UInt64?,
                state: State, reasons: [String] = []) {
        self.name = name
        self.path = path
        self.externalPath = externalPath
        self.sizeBytes = sizeBytes
        self.state = state
        self.reasons = reasons
    }

    public static func rows(scan: ScanReport?, status: StatusReport?) -> [Self] {
        guard let scan else { return [] }
        var rows: [String: Self] = [:]
        func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        for app in scan.candidates where app.kind == .application {
            let state: State
            switch app.compatibility?.grade {
            case .safe: state = .ready
            case .popupRisk: state = .review
            case .blocked: state = .blocked
            case nil: state = .unverified
            }
            rows[key(app.path)] = Self(name: app.name, path: app.path, sizeBytes: app.sizeBytes,
                                      state: state, reasons: app.compatibility?.reasons ?? [])
        }
        for app in scan.externalApplications {
            let connected = status?.externalVolumes.contains {
                app.destinationPath.hasPrefix($0.path + "/")
            } ?? false
            let state: State
            switch app.managementStatus {
            case .macBay: state = connected ? .external : .unavailable
            case .unmanaged: state = .unmanaged
            case .unconfirmed: state = .unverified
            }
            rows[key(app.sourcePath)] = Self(
                name: app.name, path: app.sourcePath, externalPath: app.destinationPath,
                sizeBytes: app.sizeBytes, state: state,
                reasons: state == .unmanaged ? ["Use the CLI adopt workflow to review this existing external link."] : []
            )
        }
        for app in scan.unresolvedApplicationLinks {
            rows[key(app.sourcePath)] = Self(name: app.name, path: app.sourcePath,
                externalPath: app.destinationPath, sizeBytes: nil, state: .unavailable, reasons: [app.reason])
        }
        return rows.values.sorted {
            if $0.sizeBytes != $1.sizeBytes { return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public struct GUIInfoRow: Identifiable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label + "|" + value }
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct GUIPreview: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let rows: [GUIInfoRow]
    public let messages: [String]
    public let needsReview: Bool

    public init(title: String, subtitle: String, rows: [GUIInfoRow], messages: [String] = [],
                needsReview: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        self.messages = messages
        self.needsReview = needsReview
    }
}

public enum GUIError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

enum GUIFormat {
    static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }
    static func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
