import Foundation

public enum PurgeSafety {
    public static let maxScanEntriesPerDirectory = 4000

    public enum Rejection: Equatable, Sendable {
        case missing
        case symbolicLink
        case notADirectory
        case outsideHome
        case notWhitelisted

        public var reason: String {
            switch self {
            case .missing:
                return "Path does not exist"
            case .symbolicLink:
                return "Path is a symbolic link"
            case .notADirectory:
                return "Path is not a directory"
            case .outsideHome:
                return "Path is outside the user home directory"
            case .notWhitelisted:
                return "Path is not in the purge whitelist"
            }
        }
    }

    public static func isContainedInHome(_ url: URL, homeDirectory: URL) -> Bool {
        isContained(url, under: homeDirectory)
    }

    static func isContained(_ url: URL, under root: URL) -> Bool {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedURL.path
        let rootPath = resolvedRoot.path
        if path == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) {
            return true
        }
        // Handle macOS /private/var vs /var symlink divergence for paths
        let unprivPath = path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path
        let unprivRoot = rootPath.hasPrefix("/private/") ? String(rootPath.dropFirst(8)) : rootPath
        if unprivPath == unprivRoot {
            return true
        }
        let unprivPrefix = unprivRoot.hasSuffix("/") ? unprivRoot : unprivRoot + "/"
        return unprivPath.hasPrefix(unprivPrefix)
    }

    public static func validate(
        _ url: URL,
        category: PurgeCategory,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Rejection? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return .missing
        }
        if values.isSymbolicLink == true {
            return .symbolicLink
        }
        guard values.isDirectory == true else {
            return .notADirectory
        }

        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedHome = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedPath != resolvedHome, isContainedInHome(url, homeDirectory: homeDirectory) else {
            return .outsideHome
        }

        let name = url.lastPathComponent
        let library = homeDirectory.appendingPathComponent("Library")
        func normalizedResolvedPath(_ u: URL) -> String {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            return p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p
        }
        let targetPath = normalizedResolvedPath(url)

        switch category {
        case .chromiumCache:
            guard PurgeEngine.whitelistedChromiumDirectories.contains(name),
                  isContained(url, under: library.appendingPathComponent("Application Support")) else {
                return .notWhitelisted
            }
        case .updateArchive:
            guard name == "ShipIt",
                  isContained(url, under: library.appendingPathComponent("Caches")) else {
                return .notWhitelisted
            }
        case .homebrewCache:
            guard targetPath == normalizedResolvedPath(library.appendingPathComponent("Caches/Homebrew")) else {
                return .notWhitelisted
            }
        case .diagnosticLog:
            guard targetPath == normalizedResolvedPath(library.appendingPathComponent("Logs/DiagnosticReports")) else {
                return .notWhitelisted
            }
        }

        return nil
    }
}
