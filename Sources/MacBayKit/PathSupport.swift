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

    public static func cachesRoot(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("Caches", isDirectory: true)
    }

    public static func manifestURL(on volume: URL) -> URL {
        externalRoot(on: volume).appendingPathComponent("manifest.json")
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
        var manifest = try load(on: volume)
        try update(&manifest)
        try save(manifest, on: volume)
    }
}
