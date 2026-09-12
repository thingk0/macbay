import Foundation

public struct PurgeEngine {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let sizeCalculator: FileSizeCalculator
    private let homeDirectory: URL

    public static let whitelistedChromiumDirectories: Set<String> = [
        "CacheStorage",
        "Code Cache",
        "GPUCache",
        "GPUPersistentCache",
        "DawnCache",
        "blob_storage"
    ]

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.homeDirectory = homeDirectory
    }

    public func scan(options: PurgeOptions = PurgeOptions()) -> [PurgeItem] {
        let runningProcessNames = detectRunningProcesses()
        var discoveredItems: [PurgeItem] = []

        // 1. Scan Application Support for Chromium/Electron caches
        discoveredItems.append(contentsOf: scanApplicationSupport(options: options, runningProcesses: runningProcessNames))

        // 2. Scan Caches for ShipIt update archives
        discoveredItems.append(contentsOf: scanShipItCaches(options: options, runningProcesses: runningProcessNames))

        // 3. Scan Homebrew caches if enabled
        if options.includeHomebrew {
            if let brewItem = scanHomebrewCache() {
                discoveredItems.append(brewItem)
            }
        }

        // 4. Scan Diagnostic Logs if enabled
        if options.includeLogs {
            if let logItem = scanDiagnosticLogs() {
                discoveredItems.append(logItem)
            }
        }

        // 5. Apply app filter if specified
        if !options.appFilter.isEmpty {
            let normalizedFilters = options.appFilter.map { $0.lowercased() }
            discoveredItems = discoveredItems.filter { item in
                normalizedFilters.contains { filter in
                    item.appName.lowercased().contains(filter)
                }
            }
        }

        // 6. Exclude zero-byte caches to keep output clean and actionable
        discoveredItems = discoveredItems.filter { $0.sizeBytes > 0 }

        return discoveredItems.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public func execute(
        items: [PurgeItem],
        options: PurgeOptions = PurgeOptions(),
        dryRun: Bool
    ) throws -> PurgeReport {
        var purged: [PurgeItem] = []
        var skipped: [PurgeItem] = []
        var totalReclaimed: UInt64 = 0

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            guard fileManager.fileExists(atPath: url.path) else { continue }

            if item.isRunning && !options.includeRunning {
                skipped.append(item)
                continue
            }

            if dryRun {
                purged.append(item)
                totalReclaimed += item.sizeBytes
            } else {
                let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in children {
                    try? fileManager.removeItem(at: child)
                }
                purged.append(item)
                totalReclaimed += item.sizeBytes
            }
        }

        var messages: [String] = []
        if dryRun {
            messages.append("Dry run: no files were removed")
        } else {
            messages.append("Purge completed successfully")
        }

        if !skipped.isEmpty {
            messages.append("Skipped \(skipped.count) cache(s) because the associated application is currently running (use --include-running to override)")
        }

        return PurgeReport(
            dryRun: dryRun,
            purgedItems: purged,
            skippedItems: skipped,
            totalReclaimedBytes: totalReclaimed,
            messages: messages
        )
    }

    // MARK: - Scanners

    private func scanApplicationSupport(options: PurgeOptions, runningProcesses: Set<String>) -> [PurgeItem] {
        let appSupportURL = homeDirectory.appendingPathComponent("Library/Application Support")
        guard fileManager.fileExists(atPath: appSupportURL.path),
              let appDirs = try? fileManager.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var items: [PurgeItem] = []

        for appDir in appDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: appDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let appName = appDir.lastPathComponent
            let isRunning = isAppRunning(appName: appName, runningProcesses: runningProcesses)

            // Search depth 1 to 3 for whitelisted folders
            let foundTargets = findWhitelistedFolders(in: appDir, depth: 1, maxDepth: 3)
            for target in foundTargets {
                let size = (try? sizeCalculator.size(of: target)) ?? 0
                items.append(PurgeItem(
                    appName: appName,
                    path: target.path,
                    category: .chromiumCache,
                    sizeBytes: size,
                    isRunning: isRunning
                ))
            }
        }

        return items
    }

    private func findWhitelistedFolders(in directory: URL, depth: Int, maxDepth: Int) -> [URL] {
        guard depth <= maxDepth,
              let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var results: [URL] = []
        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let name = item.lastPathComponent
            if Self.whitelistedChromiumDirectories.contains(name) {
                results.append(item)
            } else if depth < maxDepth {
                results.append(contentsOf: findWhitelistedFolders(in: item, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return results
    }

    private func scanShipItCaches(options: PurgeOptions, runningProcesses: Set<String>) -> [PurgeItem] {
        let cachesURL = homeDirectory.appendingPathComponent("Library/Caches")
        guard fileManager.fileExists(atPath: cachesURL.path),
              let subDirs = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var items: [PurgeItem] = []
        for subDir in subDirs {
            let shipItURL = subDir.appendingPathComponent("ShipIt")
            guard fileManager.fileExists(atPath: shipItURL.path) else { continue }

            let appName = subDir.lastPathComponent
            let isRunning = isAppRunning(appName: appName, runningProcesses: runningProcesses)
            let size = (try? sizeCalculator.size(of: shipItURL)) ?? 0

            items.append(PurgeItem(
                appName: appName,
                path: shipItURL.path,
                category: .updateArchive,
                sizeBytes: size,
                isRunning: isRunning
            ))
        }

        return items
    }

    private func scanHomebrewCache() -> PurgeItem? {
        let brewCacheURL = homeDirectory.appendingPathComponent("Library/Caches/Homebrew")
        guard fileManager.fileExists(atPath: brewCacheURL.path) else { return nil }

        let size = (try? sizeCalculator.size(of: brewCacheURL)) ?? 0
        return PurgeItem(
            appName: "Homebrew",
            path: brewCacheURL.path,
            category: .homebrewCache,
            sizeBytes: size,
            isRunning: false
        )
    }

    private func scanDiagnosticLogs() -> PurgeItem? {
        let logsURL = homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard fileManager.fileExists(atPath: logsURL.path) else { return nil }

        let size = (try? sizeCalculator.size(of: logsURL)) ?? 0
        return PurgeItem(
            appName: "Diagnostic Reports",
            path: logsURL.path,
            category: .diagnosticLog,
            sizeBytes: size,
            isRunning: false
        )
    }

    // MARK: - Process Detection

    private func detectRunningProcesses() -> Set<String> {
        guard let result = try? commandRunner.run("/bin/ps", arguments: ["-eo", "comm="]),
              result.status == 0 else {
            return []
        }

        let names = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                URL(fileURLWithPath: String(line)).lastPathComponent.lowercased()
            }
        return Set(names)
    }

    private func isAppRunning(appName: String, runningProcesses: Set<String>) -> Bool {
        let normalized = appName.lowercased()
        if runningProcesses.contains(normalized) {
            return true
        }
        if runningProcesses.contains(normalized + ".app") {
            return true
        }
        return false
    }
}
