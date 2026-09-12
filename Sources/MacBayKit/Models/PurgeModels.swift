import Foundation

public enum PurgeCategory: String, Codable, Equatable, Sendable {
    case chromiumCache = "chromium_cache"
    case updateArchive = "update_archive"
    case homebrewCache = "homebrew_cache"
    case diagnosticLog = "diagnostic_log"

    public var displayName: String {
        switch self {
        case .chromiumCache: return "Chromium/Electron Cache"
        case .updateArchive: return "Update Archive"
        case .homebrewCache: return "Homebrew Downloads"
        case .diagnosticLog: return "Diagnostic Logs"
        }
    }
}

public struct PurgeItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let appName: String
    public let path: String
    public let category: PurgeCategory
    public let sizeBytes: UInt64
    public let isRunning: Bool

    public init(
        appName: String,
        path: String,
        category: PurgeCategory,
        sizeBytes: UInt64,
        isRunning: Bool
    ) {
        self.id = path
        self.appName = appName
        self.path = path
        self.category = category
        self.sizeBytes = sizeBytes
        self.isRunning = isRunning
    }
}

public struct PurgeReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let dryRun: Bool
    public let purgedItems: [PurgeItem]
    public let skippedItems: [PurgeItem]
    public let totalReclaimedBytes: UInt64
    public let messages: [String]

    public init(
        generatedAt: String = macBayTimestamp(),
        dryRun: Bool,
        purgedItems: [PurgeItem],
        skippedItems: [PurgeItem] = [],
        totalReclaimedBytes: UInt64,
        messages: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.dryRun = dryRun
        self.purgedItems = purgedItems
        self.skippedItems = skippedItems
        self.totalReclaimedBytes = totalReclaimedBytes
        self.messages = messages
    }
}

public struct PurgeOptions: Sendable {
    public var appFilter: [String]
    public var includeRunning: Bool
    public var includeLogs: Bool
    public var includeHomebrew: Bool

    public init(
        appFilter: [String] = [],
        includeRunning: Bool = false,
        includeLogs: Bool = false,
        includeHomebrew: Bool = true
    ) {
        self.appFilter = appFilter
        self.includeRunning = includeRunning
        self.includeLogs = includeLogs
        self.includeHomebrew = includeHomebrew
    }
}
