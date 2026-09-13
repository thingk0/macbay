import Foundation

public enum MacBayPaths {
    public static let externalRootName = "MacBay"

    public static func expandedURL(_ path: String) -> URL {
        let expandedPath: String
        if path == "~" {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expandedPath = path
        }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    public static func externalRoot(on volume: URL) -> URL {
        volume.appendingPathComponent(externalRootName, isDirectory: true)
    }

    public static func applicationsRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Applications", isDirectory: true)
    }

    public static func xcodeRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Xcode", isDirectory: true)
    }

    public static func xcodeArchivesRoot(on volume: URL) -> URL {
        xcodeRoot(on: volume).appendingPathComponent("Archives", isDirectory: true)
    }

    public static func xcodeDerivedDataRoot(on volume: URL) -> URL {
        xcodeRoot(on: volume).appendingPathComponent("DerivedData", isDirectory: true)
    }

    public static func defaultXcodeDeviceSupportURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
    }

    public static func defaultXcodeArchivesURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Developer/Xcode/Archives")
    }

    public static func defaultXcodeDerivedDataURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    public static func defaultCoreSimulatorCachesURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
    }

    public static func defaultXcodeCachesURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Caches/com.apple.dt.Xcode")
    }

    public static func cachesRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Caches", isDirectory: true)
    }

    public static func dataRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Data", isDirectory: true)
    }

    public static func manifestURL(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("manifest.json")
    }

    public static func manifestLockURL(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent(".manifest.lock")
    }

    public static func operationsRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent(".operations", isDirectory: true)
    }

    public static func backupsRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Backups", isDirectory: true)
    }

    public static func applicationURL(named name: String) -> URL {
        if name.hasPrefix("/") || name.hasPrefix("~/") || name.contains("/") {
            return expandedURL(name)
        }
        let appName = name.hasSuffix(".app") ? name : "\(name).app"
        return URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
    }
}

public struct FileSizeCalculator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func size(of url: URL) throws -> UInt64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MacBayError.pathMissing(url.path)
        }

        if !isDirectory.boolValue {
            return try fileSize(of: url)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: UInt64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isDirectory != true, let fileSize = values.fileSize, fileSize > 0 {
                total = total.addingReportingOverflow(UInt64(fileSize)).partialValue
            }
        }
        return total
    }

    private func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else { return 0 }
        return number.uint64Value
    }
}

public struct FileLock: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw MacBayError.commandFailed(
                executable: "open",
                status: errno,
                details: "Failed to open lock file at \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer {
            close(fd)
        }

        guard flock(fd, LOCK_EX) == 0 else {
            throw MacBayError.commandFailed(
                executable: "flock",
                status: errno,
                details: "Failed to acquire lock on \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer {
            flock(fd, LOCK_UN)
        }

        return try body()
    }
}

public struct ManifestStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load(on volume: URL) throws -> DockManifest {
        let manifestURL = MacBayPaths.manifestURL(on: volume)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return DockManifest()
        }
        do {
            return try decoder.decode(DockManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw MacBayError.manifestFailed(path: manifestURL.path, details: error.localizedDescription)
        }
    }

    public func save(_ manifest: DockManifest, on volume: URL) throws {
        let root = MacBayPaths.externalRoot(on: volume)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder.encode(manifest)
            try data.write(to: MacBayPaths.manifestURL(on: volume), options: .atomic)
        } catch {
            throw MacBayError.manifestFailed(
                path: MacBayPaths.manifestURL(on: volume).path,
                details: error.localizedDescription
            )
        }
    }

    public func updating(
        on volume: URL,
        _ update: (inout DockManifest) throws -> Void
    ) throws {
        let lock = FileLock(url: MacBayPaths.manifestLockURL(on: volume))
        try lock.withLock {
            var manifest = try load(on: volume)
            try update(&manifest)
            try save(manifest, on: volume)
        }
    }
}

public struct OperationJournal {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func recordURL(for appName: String, on volume: URL) -> URL {
        MacBayPaths.operationsRoot(on: volume).appendingPathComponent("adopt-\(appName).json")
    }

    public func save(_ record: AdoptOperationRecord, on volume: URL) throws {
        let dir = MacBayPaths.operationsRoot(on: volume)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = recordURL(for: record.appName, on: volume)
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func remove(for appName: String, on volume: URL) {
        let url = recordURL(for: appName, on: volume)
        try? fileManager.removeItem(at: url)
    }

    public func load(for appName: String, on volume: URL) -> AdoptOperationRecord? {
        let url = recordURL(for: appName, on: volume)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AdoptOperationRecord.self, from: data)
    }

    public func listIncompleteOperations(on volume: URL) -> [AdoptOperationRecord] {
        let dir = MacBayPaths.operationsRoot(on: volume)
        guard fileManager.fileExists(atPath: dir.path),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(AdoptOperationRecord.self, from: data),
                  record.phase != .completed else {
                return nil
            }
            return record
        }
    }
}

extension FileManager {
    /// Deletes a tree even when it contains read-only directories (Go's
    /// `~/go/pkg/mod` marks module directories `0500`, which makes a plain
    /// `removeItem` fail partway). Marks every directory writable first so the
    /// removal completes instead of leaving a half-deleted tree.
    public func removeItemMakingWritable(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isSymlink = (try? destinationOfSymbolicLink(atPath: url.path)) != nil
        if exists, isDirectory.boolValue, !isSymlink {
            relaxPermissionsForMove(at: url)
        }
        try removeItem(at: url)
    }

    /// Best-effort chmod of every directory in a tree so `moveItem`/rename and
    /// later removal work on read-only trees (e.g. Go's module cache uses 0500).
    /// Symlinks and files are untouched; non-directories and missing paths are no-ops.
    public func relaxPermissionsForMove(at url: URL) {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? destinationOfSymbolicLink(atPath: url.path)) == nil else { return }
        if let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            for case let child as URL in enumerator {
                guard let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try? setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            }
        }
        try? setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public struct DockRefresher {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    public func refresh(for appURL: URL) -> [String] {
        var warnings: [String] = []
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fileManager.isExecutableFile(atPath: lsregisterPath) {
            do {
                let result = try commandRunner.run(lsregisterPath, arguments: ["-f", appURL.path])
                if result.status != 0 {
                    warnings.append("Warning: lsregister failed with status \(result.status)")
                }
            } catch {
                warnings.append("Warning: lsregister failed: \(error.localizedDescription)")
            }
        }
        do {
            let result = try commandRunner.run("/usr/bin/killall", arguments: ["Dock"])
            if result.status != 0 {
                warnings.append("Warning: killall Dock failed with status \(result.status)")
            }
        } catch {
            warnings.append("Warning: killall Dock failed: \(error.localizedDescription)")
        }
        return warnings
    }
}

