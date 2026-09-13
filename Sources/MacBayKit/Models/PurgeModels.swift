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

public struct PurgeFailure: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let appName: String
    public let path: String
    public let reason: String
    public let unreclaimedBytes: UInt64

    public init(
        appName: String,
        path: String,
        reason: String,
        unreclaimedBytes: UInt64 = 0
    ) {
        self.appName = appName
        self.path = path
        self.reason = reason
        self.unreclaimedBytes = unreclaimedBytes
    }
}

public struct PurgeReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let dryRun: Bool
    public let purgedItems: [PurgeItem]
    public let skippedItems: [PurgeItem]
    public let failedItems: [PurgeFailure]
    public let totalReclaimedBytes: UInt64
    public let messages: [String]

    public init(
        generatedAt: String = macBayTimestamp(),
        dryRun: Bool,
        purgedItems: [PurgeItem],
        skippedItems: [PurgeItem] = [],
        failedItems: [PurgeFailure] = [],
        totalReclaimedBytes: UInt64,
        messages: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.dryRun = dryRun
        self.purgedItems = purgedItems
        self.skippedItems = skippedItems
        self.failedItems = failedItems
        self.totalReclaimedBytes = totalReclaimedBytes
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case dryRun
        case purgedItems
        case skippedItems
        case failedItems
        case totalReclaimedBytes
        case messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? macBayTimestamp()
        self.dryRun = try container.decode(Bool.self, forKey: .dryRun)
        self.purgedItems = try container.decode([PurgeItem].self, forKey: .purgedItems)
        self.skippedItems = try container.decodeIfPresent([PurgeItem].self, forKey: .skippedItems) ?? []
        self.failedItems = try container.decodeIfPresent([PurgeFailure].self, forKey: .failedItems) ?? []
        self.totalReclaimedBytes = try container.decode(UInt64.self, forKey: .totalReclaimedBytes)
        self.messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? []
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

public struct PurgeAppGroup: Identifiable, Equatable, Sendable {
    public var id: String { appName }
    public let appName: String
    public let items: [PurgeItem]
    public var totalSizeBytes: UInt64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    public init(appName: String, items: [PurgeItem]) {
        self.appName = appName
        self.items = items
    }

    public static func group(items: [PurgeItem]) -> [PurgeAppGroup] {
        var dict: [String: [PurgeItem]] = [:]
        for item in items {
            dict[item.appName, default: []].append(item)
        }
        return dict.map { PurgeAppGroup(appName: $0.key, items: $0.value) }
            .sorted { $0.totalSizeBytes > $1.totalSizeBytes }
    }

    public static func parseSelection(input: String, groupCount: Int) -> Set<Int>? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let cancelKeywords: Set<String> = ["q", "quit", "n", "no", "cancel"]
        if cancelKeywords.contains(trimmed) {
            return nil
        }

        let allKeywords: Set<String> = ["1", "all", "a", "y", "yes"]
        if allKeywords.contains(trimmed) {
            return Set(0..<groupCount)
        }

        var selectedIndices = Set<Int>()
        let tokens = trimmed.split { $0 == "," || $0 == " " }.map(String.init)
        guard !tokens.isEmpty else { return nil }

        for token in tokens {
            if token.contains("-") {
                let parts = token.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2, parts[0] <= parts[1] else { return nil }
                for num in parts[0]...parts[1] {
                    if num == 1 {
                        return Set(0..<groupCount)
                    }
                    let idx = num - 2
                    guard idx >= 0 && idx < groupCount else { return nil }
                    selectedIndices.insert(idx)
                }
            } else if let num = Int(token) {
                if num == 1 {
                    return Set(0..<groupCount)
                }
                let idx = num - 2
                guard idx >= 0 && idx < groupCount else { return nil }
                selectedIndices.insert(idx)
            } else {
                return nil
            }
        }

        return selectedIndices.isEmpty ? nil : selectedIndices
    }
}

