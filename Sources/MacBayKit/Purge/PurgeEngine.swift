import Foundation

public struct PurgeEngine {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let sizeCalculator: FileSizeCalculator
    private let homeDirectory: URL

    public static let maxScanEntriesPerDirectory = PurgeSafety.maxScanEntriesPerDirectory

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

    private func children(of directory: URL) throws -> (entries: [URL], truncated: Bool) {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (
            Array(contents.prefix(Self.maxScanEntriesPerDirectory)),
            contents.count > Self.maxScanEntriesPerDirectory
        )
    }

    private func safeChildren(of directory: URL) -> [URL] {
        ((try? children(of: directory))?.entries) ?? []
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

        // 7. Authority validation gate
        discoveredItems = discoveredItems.filter { item in
            PurgeSafety.validate(
                URL(fileURLWithPath: item.path),
                category: item.category,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) == nil
        }

        return discoveredItems.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public func execute(
        items: [PurgeItem],
        options: PurgeOptions = PurgeOptions(),
        dryRun: Bool
    ) throws -> PurgeReport {
        var purged: [PurgeItem] = []
        var skipped: [PurgeItem] = []
        var failed: [PurgeFailure] = []
        var truncatedPaths: [String] = []
        var totalReclaimed: UInt64 = 0

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            if let rejection = PurgeSafety.validate(
                url,
                category: item.category,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) {
                if rejection == .missing { continue }
                failed.append(PurgeFailure(
                    appName: item.appName,
                    path: item.path,
                    reason: rejection.reason,
                    unreclaimedBytes: item.sizeBytes
                ))
                continue
            }

            if item.isRunning && !options.includeRunning {
                skipped.append(item)
                continue
            }

            if dryRun {
                purged.append(item)
                totalReclaimed += item.sizeBytes
                continue
            }

            let listing: (entries: [URL], truncated: Bool)
            do {
                listing = try children(of: url)
            } catch {
                failed.append(PurgeFailure(
                    appName: item.appName,
                    path: item.path,
                    reason: "Unable to list directory: \(error.localizedDescription)",
                    unreclaimedBytes: item.sizeBytes
                ))
                continue
            }

            var reclaimed: UInt64 = 0
            var itemFailures: [PurgeFailure] = []
            var removedAny = false

            for child in listing.entries {
                let childSize = (try? sizeCalculator.size(of: child)) ?? 0
                do {
                    try fileManager.removeItemMakingWritable(at: child)
                    reclaimed += childSize
                    removedAny = true
                } catch {
                    itemFailures.append(PurgeFailure(
                        appName: item.appName,
                        path: child.path,
                        reason: error.localizedDescription,
                        unreclaimedBytes: childSize
                    ))
                }
            }

            if listing.truncated {
                truncatedPaths.append(item.path)
            }

            failed.append(contentsOf: itemFailures)
            if removedAny || itemFailures.isEmpty {
                purged.append(PurgeItem(
                    appName: item.appName,
                    path: item.path,
                    category: item.category,
                    sizeBytes: reclaimed,
                    isRunning: item.isRunning
                ))
                totalReclaimed += reclaimed
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

        if !failed.isEmpty {
            messages.append("Could not remove \(failed.count) item(s); see failedItems for details")
        }

        if !truncatedPaths.isEmpty {
            messages.append("Processed only the first \(Self.maxScanEntriesPerDirectory) entries in \(truncatedPaths.count) directory(ies); re-run to continue")
        }

        return PurgeReport(
            dryRun: dryRun,
            purgedItems: purged,
            skippedItems: skipped,
            failedItems: failed,
            totalReclaimedBytes: totalReclaimed,
            messages: messages
        )
    }

    // MARK: - Scanners

    private func scanApplicationSupport(options: PurgeOptions, runningProcesses: Set<String>) -> [PurgeItem] {
        let appSupportURL = homeDirectory.appendingPathComponent("Library/Application Support")
        guard fileManager.fileExists(atPath: appSupportURL.path) else {
            return []
        }

        var items: [PurgeItem] = []
        let appDirs = safeChildren(of: appSupportURL)

        for appDir in appDirs {
            let values = try? appDir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                continue
            }

            let appName = appDir.lastPathComponent
            let isRunning = isAppRunning(appName: appName, runningProcesses: runningProcesses)

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
        guard depth <= maxDepth else {
            return []
        }

        var results: [URL] = []
        let contents = safeChildren(of: directory)
        for item in contents {
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                continue
            }

            let name = item.lastPathComponent
            if Self.whitelistedChromiumDirectories.contains(name) {
                if PurgeSafety.validate(
                    item,
                    category: .chromiumCache,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                ) == nil {
                    results.append(item)
                }
            } else if depth < maxDepth {
                results.append(contentsOf: findWhitelistedFolders(in: item, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return results
    }

    private func scanShipItCaches(options: PurgeOptions, runningProcesses: Set<String>) -> [PurgeItem] {
        let cachesURL = homeDirectory.appendingPathComponent("Library/Caches")
        guard fileManager.fileExists(atPath: cachesURL.path) else {
            return []
        }

        var items: [PurgeItem] = []
        let subDirs = safeChildren(of: cachesURL)
        for subDir in subDirs {
            let values = try? subDir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                continue
            }

            let shipItURL = subDir.appendingPathComponent("ShipIt")
            guard PurgeSafety.validate(
                shipItURL,
                category: .updateArchive,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) == nil else {
                continue
            }

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
        guard PurgeSafety.validate(
            brewCacheURL,
            category: .homebrewCache,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) == nil else {
            return nil
        }

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
        guard PurgeSafety.validate(
            logsURL,
            category: .diagnosticLog,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) == nil else {
            return nil
        }

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
