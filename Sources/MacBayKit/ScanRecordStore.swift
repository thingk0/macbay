import Foundation

public struct ScanRecordStore {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public var stateDirectory: URL {
        if let xdgStateHome = environment["XDG_STATE_HOME"], xdgStateHome.hasPrefix("/") {
            return URL(fileURLWithPath: xdgStateHome, isDirectory: true)
                .appendingPathComponent("macbay")
        }
        return homeDirectory.appendingPathComponent(".local/state/macbay")
    }

    public var scansDirectory: URL {
        stateDirectory.appendingPathComponent("scans")
    }

    public func recordURL(forRootPath rootPath: String) -> URL {
        let digest = stableDigest(rootPath)
        return scansDirectory.appendingPathComponent("explore-\(digest).json")
    }

    public func load(forRootPath rootPath: String) -> ExplorerScanReport? {
        let url = recordURL(forRootPath: rootPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let report = try? decoder.decode(ExplorerScanReport.self, from: data)
        guard report?.rootPath == standardized(rootPath) else { return nil }
        return report
    }

    public func save(_ report: ExplorerScanReport) throws {
        try fileManager.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
        let url = recordURL(forRootPath: report.rootPath)
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    public func buildReport(from scan: ExplorerScan, previous: ExplorerScanReport? = nil) -> ExplorerScanReport {
        let deltas: [ExplorerDelta]
        let previousGeneratedAt: String?
        if let previous, previous.rootPath == scan.rootPath, previous.complete, scan.complete {
            previousGeneratedAt = previous.generatedAt
            deltas = diff(current: scan.entries, previous: previous.entries)
        } else {
            previousGeneratedAt = previous?.generatedAt
            deltas = scan.entries.map { entry in
                ExplorerDelta(
                    path: entry.path,
                    name: entry.name,
                    previousAllocatedBytes: nil,
                    currentAllocatedBytes: entry.allocatedBytes,
                    deltaAllocatedBytes: nil,
                    status: .uncomparable
                )
            }
        }
        return ExplorerScanReport(
            rootPath: scan.rootPath,
            generatedAt: macBayTimestamp(),
            previousGeneratedAt: previousGeneratedAt,
            entries: scan.entries,
            totalLogicalBytes: scan.totalLogicalBytes,
            totalAllocatedBytes: scan.totalAllocatedBytes,
            complete: scan.complete,
            unreadablePaths: scan.unreadablePaths,
            warnings: scan.warnings,
            deltas: deltas
        )
    }

    public func diff(current: [ExplorerEntry], previous: [ExplorerEntry]) -> [ExplorerDelta] {
        let previousByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        let currentPaths = Set(current.map(\.path))
        var deltas = current.map { entry -> ExplorerDelta in
            guard let old = previousByPath[entry.path] else {
                return ExplorerDelta(
                    path: entry.path,
                    name: entry.name,
                    previousAllocatedBytes: nil,
                    currentAllocatedBytes: entry.allocatedBytes,
                    deltaAllocatedBytes: nil,
                    status: .added
                )
            }
            if old.allocatedBytes == entry.allocatedBytes {
                return ExplorerDelta(
                    path: entry.path,
                    name: entry.name,
                    previousAllocatedBytes: old.allocatedBytes,
                    currentAllocatedBytes: entry.allocatedBytes,
                    deltaAllocatedBytes: 0,
                    status: .unchanged
                )
            }
            let delta = Int64(clamping: entry.allocatedBytes) - Int64(clamping: old.allocatedBytes)
            return ExplorerDelta(
                path: entry.path,
                name: entry.name,
                previousAllocatedBytes: old.allocatedBytes,
                currentAllocatedBytes: entry.allocatedBytes,
                deltaAllocatedBytes: delta,
                status: delta > 0 ? .grown : .shrunk
            )
        }
        for old in previous where !currentPaths.contains(old.path) {
            deltas.append(ExplorerDelta(
                path: old.path,
                name: old.name,
                previousAllocatedBytes: old.allocatedBytes,
                currentAllocatedBytes: 0,
                deltaAllocatedBytes: old.allocatedBytes == 0 ? 0 : -Int64(clamping: old.allocatedBytes),
                status: .removed
            ))
        }
        return deltas.sorted {
            let lhsDelta = $0.deltaAllocatedBytes ?? Int64.min
            let rhsDelta = $1.deltaAllocatedBytes ?? Int64.min
            if lhsDelta != rhsDelta { return lhsDelta > rhsDelta }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func stableDigest(_ rootPath: String) -> String {
        let standardizedPath = standardized(rootPath)
        var hash: UInt64 = 14_695_959_421_393_173
        for byte in standardizedPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_096_031_521_372_021
        }
        return String(format: "%016llx", hash)
    }
}
