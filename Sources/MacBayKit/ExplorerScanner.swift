import Foundation

public struct ExplorerScanner {
    private let fileManager: FileManager
    private let diskInfoProvider: (any DiskInfoProvider)?
    private let maximumEntries: Int

    public init(
        fileManager: FileManager = .default,
        diskInfoProvider: (any DiskInfoProvider)? = nil,
        maximumEntries: Int = 500
    ) {
        self.fileManager = fileManager
        self.diskInfoProvider = diskInfoProvider
        self.maximumEntries = maximumEntries
    }

    public func scanDirectory(
        _ root: URL,
        progress: ((ExplorerScanProgress) -> Void)? = nil
    ) -> ExplorerScan {
        let standardizedRoot = root.standardizedFileURL
        var entries: [ExplorerEntry] = []
        var unreadablePaths: [String] = []
        var warnings: [String] = []
        var totalLogical: UInt64 = 0
        var totalAllocated: UInt64 = 0
        var fileCounter = 0

        let childURLs: [URL]
        do {
            childURLs = try fileManager.contentsOfDirectory(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ExplorerScan(
                rootPath: standardizedRoot.path,
                entries: [],
                totalLogicalBytes: 0,
                totalAllocatedBytes: 0,
                complete: false,
                unreadablePaths: [standardizedRoot.path],
                warnings: ["Unable to read \(standardizedRoot.path): \(error.localizedDescription)"]
            )
        }

        for child in childURLs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            progress?(ExplorerScanProgress(
                rootPath: standardizedRoot.path,
                scannedFiles: fileCounter,
                scannedEntries: entries.count,
                currentPath: child.path
            ))
            let sized = measure(child: child, root: standardizedRoot, warnings: &warnings, unreadablePaths: &unreadablePaths)
            fileCounter += sized.fileCount
            totalLogical = totalLogical.addingReportingOverflow(sized.logical).partialValue
            totalAllocated = totalAllocated.addingReportingOverflow(sized.allocated).partialValue
            entries.append(sized.entry)
        }

        entries.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if entries.count > maximumEntries {
            entries = Array(entries.prefix(maximumEntries))
        }

        return ExplorerScan(
            rootPath: standardizedRoot.path,
            entries: entries,
            totalLogicalBytes: totalLogical,
            totalAllocatedBytes: totalAllocated,
            complete: unreadablePaths.isEmpty,
            unreadablePaths: unreadablePaths.sorted(),
            warnings: warnings
        )
    }

    private func measure(
        child: URL,
        root: URL,
        warnings: inout [String],
        unreadablePaths: inout [String]
    ) -> (entry: ExplorerEntry, logical: UInt64, allocated: UInt64, fileCount: Int) {
        let standardized = child.standardizedFileURL
        let name = standardized.lastPathComponent

        let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: standardized.path)
        if let linkDestination {
            let resolved = URL(fileURLWithPath: linkDestination, relativeTo: standardized.deletingLastPathComponent()).standardizedFileURL
            let external = isExternalTarget(resolved)
            let action: ExplorerAction = external ? .externalLink : .directoryMove
            return (ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .symlink,
                externalTarget: resolved.path,
                action: action
            ), 0, 0, 0)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            unreadablePaths.append(standardized.path)
            return (ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .other,
                unreadable: true,
                action: .unreadable
            ), 0, 0, 0)
        }

        if !isDirectory.boolValue {
            let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isReadableKey])
            if values?.isReadable == false {
                unreadablePaths.append(standardized.path)
                return (ExplorerEntry(
                    name: name,
                    path: standardized.path,
                    kind: .file,
                    unreadable: true,
                    action: .unreadable
                ), 0, 0, 0)
            }
            let logical = UInt64(max(0, values?.fileSize ?? 0))
            let allocated = UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileSize ?? 0))
            return (ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .file,
                logicalBytes: logical,
                allocatedBytes: allocated,
                fileCount: 1,
                action: movableFileAction(for: standardized)
            ), logical, allocated, 1)
        }

        if standardized.pathExtension.lowercased() == "app" {
            let tree = measureTree(standardized, warnings: &warnings, unreadablePaths: &unreadablePaths)
            if tree.unreadableRoot {
                return (ExplorerEntry(
                    name: name,
                    path: standardized.path,
                    kind: .application,
                    unreadable: true,
                    action: .unreadable
                ), 0, 0, 0)
            }
            return (ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .application,
                logicalBytes: tree.logical,
                allocatedBytes: tree.allocated,
                fileCount: tree.files,
                action: .appDock
            ), tree.logical, tree.allocated, tree.files)
        }

        let movable = movableAction(for: standardized)
        let tree = measureTree(standardized, warnings: &warnings, unreadablePaths: &unreadablePaths)
        if tree.unreadableRoot {
            return (ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .directory,
                unreadable: true,
                action: .unreadable
            ), 0, 0, 0)
        }
        let partial = tree.partial
        return (ExplorerEntry(
            name: name,
            path: standardized.path,
            kind: .directory,
            logicalBytes: tree.logical,
            allocatedBytes: tree.allocated,
            fileCount: tree.files,
            unreadable: partial,
            action: partial ? .unreadable : movable
        ), tree.logical, tree.allocated, tree.files)
    }

    private func measureTree(
        _ root: URL,
        warnings: inout [String],
        unreadablePaths: inout [String]
    ) -> (logical: UInt64, allocated: UInt64, files: Int, partial: Bool, unreadableRoot: Bool) {
        var seenInodes = Set<InodeKey>()
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var files = 0
        var partial = false
        var stack: [URL] = [root]

        while let current = stack.popLast() {
            let childURLs: [URL]
            do {
                childURLs = try fileManager.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isReadableKey, .fileResourceIdentifierKey],
                    options: []
                )
            } catch {
                partial = true
                if !unreadablePaths.contains(current.path) {
                    unreadablePaths.append(current.path)
                }
                if current == root {
                    return (0, 0, 0, true, true)
                }
                continue
            }

            for child in childURLs {
                if (try? fileManager.destinationOfSymbolicLink(atPath: child.path)) != nil {
                    continue
                }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isReadableKey, .fileResourceIdentifierKey])
                guard let values = values ?? nil else {
                    partial = true
                    if !unreadablePaths.contains(child.path) {
                        unreadablePaths.append(child.path)
                    }
                    continue
                }
                if values.isReadable == false {
                    partial = true
                    if !unreadablePaths.contains(child.path) {
                        unreadablePaths.append(child.path)
                    }
                    continue
                }
                if values.isSymbolicLink == true {
                    continue
                }
                if values.isDirectory == true {
                    stack.append(child)
                    continue
                }
                if let key = InodeKey(values: values), !seenInodes.insert(key).inserted {
                    continue
                }
                files += 1
                let fileLogical = UInt64(max(0, values.fileSize ?? 0))
                let fileAllocated = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
                logical = logical.addingReportingOverflow(fileLogical).partialValue
                allocated = allocated.addingReportingOverflow(fileAllocated).partialValue
            }
        }

        return (logical, allocated, files, partial, false)
    }

    private func isExternalTarget(_ target: URL) -> Bool {
        guard let provider = diskInfoProvider else {
            let standardized = target.standardizedFileURL.path
            return standardized.hasPrefix("/Volumes/")
        }
        guard let info = try? provider.diskInfo(for: target.path) else { return false }
        return !info.isInternal
    }

    func movableAction(for url: URL) -> ExplorerAction {
        let path = url.standardizedFileURL.path
        let homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let blockedExact = ["/Users", homePath, homePath + "/Library", homePath + "/Library/Application Support", homePath + "/Library/Caches"]
        for root in blockedExact where path == root {
            return .blocked(reason: "Refusing to externalize a protected location: \(path)")
        }
        let prefixBlocked = [
            "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var",
            "/private", "/opt", "/Applications", "/Volumes", "/dev", "/tmp", "/cores"
        ] + [
            "Containers", "Group Containers", "Mobile Documents", "Keychains",
            "Mail", "Preferences", "LaunchAgents", "LaunchDaemons", "Cookies",
            "Messages", "Safari", "Accounts", "Saved Application State", "Fonts",
            "WebKit", "Metadata", "Developer"
        ].map { homePath + "/Library/" + $0 }
            + [".ssh", ".gnupg", ".cargo", ".rustup", ".aws", ".azure", ".docker", ".config", ".Trash"]
                .map { homePath + "/" + $0 }
        for root in prefixBlocked {
            if path == root || path.hasPrefix(root + "/") {
                return .blocked(reason: "Refusing to externalize a protected location: \(path)")
            }
        }
        let managedCachePaths = Set(CacheManager.targets(homeDirectory: fileManager.homeDirectoryForCurrentUser)
            .map { $0.internalURL.standardizedFileURL.path })
        if managedCachePaths.contains(path) {
            return .blocked(reason: "This path is managed by 'mb cache'; use 'mb cache --enable' instead of moving it: \(path)")
        }
        return .directoryMove
    }

    func movableFileAction(for url: URL) -> ExplorerAction {
        switch movableAction(for: url) {
        case .directoryMove, .fileMove, .appDock:
            return .fileMove
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .externalLink:
            return .externalLink
        case .unreadable:
            return .unreadable
        }
    }
}

private struct InodeKey: Hashable {
    let identifier: AnyHashable

    init?(values: URLResourceValues) {
        guard let identifier = values.fileResourceIdentifier as? AnyHashable else { return nil }
        self.identifier = identifier
    }
}

public struct ExplorerScanProgress: Equatable, Sendable {
    public let rootPath: String
    public let scannedFiles: Int
    public let scannedEntries: Int
    public let currentPath: String?

    public init(rootPath: String, scannedFiles: Int, scannedEntries: Int, currentPath: String? = nil) {
        self.rootPath = rootPath
        self.scannedFiles = scannedFiles
        self.scannedEntries = scannedEntries
        self.currentPath = currentPath
    }
}

public struct ExplorerScan: Equatable, Sendable {
    public let rootPath: String
    public let entries: [ExplorerEntry]
    public let totalLogicalBytes: UInt64
    public let totalAllocatedBytes: UInt64
    public let complete: Bool
    public let unreadablePaths: [String]
    public let warnings: [String]

    public init(
        rootPath: String,
        entries: [ExplorerEntry],
        totalLogicalBytes: UInt64,
        totalAllocatedBytes: UInt64,
        complete: Bool = true,
        unreadablePaths: [String] = [],
        warnings: [String] = []
    ) {
        self.rootPath = rootPath
        self.entries = entries
        self.totalLogicalBytes = totalLogicalBytes
        self.totalAllocatedBytes = totalAllocatedBytes
        self.complete = complete
        self.unreadablePaths = unreadablePaths
        self.warnings = warnings
    }
}
