import Foundation

public struct ConfigScanLimits: Equatable, Sendable {
    public var maxDepth: Int
    public var maxConfigFiles: Int
    public var maxScanEntries: Int
    public var maxFileBytes: Int
    public var maxTotalReadBytes: Int

    public static let standard = ConfigScanLimits(
        maxDepth: 8,
        maxConfigFiles: 10_000,
        maxScanEntries: 100_000,
        maxFileBytes: 2 * 1024 * 1024,
        maxTotalReadBytes: 64 * 1024 * 1024
    )

    public init(
        maxDepth: Int,
        maxConfigFiles: Int,
        maxScanEntries: Int,
        maxFileBytes: Int,
        maxTotalReadBytes: Int
    ) {
        self.maxDepth = maxDepth
        self.maxConfigFiles = maxConfigFiles
        self.maxScanEntries = maxScanEntries
        self.maxFileBytes = maxFileBytes
        self.maxTotalReadBytes = maxTotalReadBytes
    }
}

enum ConfigFileFormat: Equatable {
    case json
    case plist
    case toml
    case yaml
    case text
}

struct FileIdentity: Hashable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct DiscoveredConfigFile: Equatable {
    let url: URL
    let format: ConfigFileFormat
}

enum DiscoveryIssueKind: Equatable {
    case inaccessible
    case missingAdditional
    case limitReached
}

struct ConfigDiscoveryIssue: Equatable {
    let url: URL?
    let reason: String
    let kind: DiscoveryIssueKind
}

struct ConfigDiscoveryResult: Equatable {
    let files: [DiscoveredConfigFile]
    let issues: [ConfigDiscoveryIssue]
}

enum ExtractionMethod: String, Equatable {
    case json
    case plist
    case mcp
    case text
}

struct ExtractedPathReference: Equatable {
    let path: String
    let location: String
    let method: ExtractionMethod
    let note: String?
}

struct ConfigReadIssue: Equatable {
    let location: String
    let reason: String
    let confirmedOmission: Bool
}

struct ConfigReadResult: Equatable {
    var references: [ExtractedPathReference] = []
    var issues: [ConfigReadIssue] = []
    var error: String?
    var coveredKeyPrefixes: [String] = []
    var coveredLineNumbers: Set<Int> = []

    mutating func append(contentsOf other: ConfigReadResult) {
        references.append(contentsOf: other.references)
        for issue in other.issues where !issues.contains(issue) {
            issues.append(issue)
        }
        if error == nil {
            error = other.error
        }
        for prefix in other.coveredKeyPrefixes where !coveredKeyPrefixes.contains(prefix) {
            coveredKeyPrefixes.append(prefix)
        }
        coveredLineNumbers.formUnion(other.coveredLineNumbers)
    }
}

struct AppPathReference: Equatable {
    let path: String
    let appFileName: String
    let internalPath: String

    static func parse(_ path: String) -> AppPathReference? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let appIndex = components.firstIndex(where: { component in
            component.count > 4 && component.lowercased().hasSuffix(".app")
        }) else { return nil }

        let appFileName = components[appIndex]
        let internalPath = components[(appIndex + 1)...].joined(separator: "/")
        return AppPathReference(path: path, appFileName: appFileName, internalPath: internalPath)
    }

    var possibleVolumeRoot: String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = components.firstIndex(where: { $0 == "Volumes" }),
              index + 1 < components.count else { return nil }
        return "/" + components[0...index + 1].joined(separator: "/")
    }
}

enum ExternalPathExistence: Equatable {
    case exists
    case missing
    case indeterminate(String)
}

struct ExternalApplicationScan: Equatable {
    let candidatesByName: [String: [ReplacementApp]]
    let unreadableDirectories: [String]
}

struct ReplacementApp: Equatable {
    let listingPath: String
    let identity: FileIdentity?
}

enum ExternalReferenceOutcome: Equatable {
    case current
    case candidate(path: String, appPath: String)
    case missing(reason: String)
    case unverified(reason: String)
}

public struct ExternalReferenceCheckResult: Equatable, Sendable {
    public let findings: [DoctorFinding]
    public let notes: [String]

    public init(findings: [DoctorFinding], notes: [String]) {
        self.findings = findings
        self.notes = notes
    }
}

public struct ReferenceReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let findings: [DoctorFinding]
    public let notes: [String]

    public var exitCode: Int32 {
        findings.contains { $0.status == .needsAttention || $0.status == .unableToVerify } ? 1 : 0
    }

    public init(
        generatedAt: String,
        findings: [DoctorFinding],
        notes: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.findings = findings
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, findings, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
        self.findings = try container.decodeIfPresent([DoctorFinding].self, forKey: .findings) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

enum ExternalConfigPaths {
    static func homeDirectory(environment: [String: String], fileManager: FileManager) -> URL {
        if let home = environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    static func xdgConfigHome(environment: [String: String], homeDirectory: URL) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".config", isDirectory: true)
    }

    static func resolveUserPath(
        _ raw: String,
        homeDirectory: URL,
        currentDirectory: URL
    ) -> URL {
        if raw == "~" {
            return homeDirectory.standardizedFileURL
        }
        if raw.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).standardizedFileURL
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return currentDirectory.appendingPathComponent(raw).standardizedFileURL
    }
}

struct MCPExtractedValue: Equatable {
    let value: String
    let location: String
}

struct MCPExtractedServer: Equatable {
    var command: MCPExtractedValue?
    var args: [MCPExtractedValue] = []
    var env: [MCPExtractedValue] = []
    var isDisabled = false
}

struct MCPExtractionIssue: Equatable {
    let location: String
    let reason: String
    let serverName: String?
}

struct MCPExtraction: Equatable {
    var servers: [String: MCPExtractedServer] = [:]
    var issues: [MCPExtractionIssue] = []
    var error: String?
    var coveredLineNumbers: Set<Int> = []

    mutating func setCommand(_ value: String, location: String, server name: String) {
        var entry = servers[name] ?? MCPExtractedServer()
        entry.command = MCPExtractedValue(value: value, location: location)
        servers[name] = entry
    }

    mutating func appendArgument(_ value: String, location: String, server name: String) {
        var entry = servers[name] ?? MCPExtractedServer()
        entry.args.append(MCPExtractedValue(value: value, location: location))
        servers[name] = entry
    }

    mutating func appendEnvironment(_ value: String, location: String, server name: String) {
        var entry = servers[name] ?? MCPExtractedServer()
        entry.env.append(MCPExtractedValue(value: value, location: location))
        servers[name] = entry
    }

    mutating func markDisabled(server name: String) {
        var entry = servers[name] ?? MCPExtractedServer()
        entry.isDisabled = true
        servers[name] = entry
    }

    mutating func recordIssue(location: String, reason: String, serverName: String?) {
        guard !issues.contains(where: { $0.location == location && $0.reason == reason }) else { return }
        issues.append(MCPExtractionIssue(location: location, reason: reason, serverName: serverName))
    }
}
