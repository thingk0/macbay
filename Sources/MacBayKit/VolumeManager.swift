import Foundation

public struct VolumeDiskInfo: Codable, Equatable, Sendable {
    public let mountPoint: String
    public let isInternal: Bool
    public let filesystemType: String
    public let isWritableVolume: Bool
    public let busProtocol: String
    public let volumeName: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let volumeUUID: String?

    public init(
        mountPoint: String,
        isInternal: Bool,
        filesystemType: String,
        isWritableVolume: Bool,
        busProtocol: String,
        volumeName: String,
        totalBytes: UInt64,
        availableBytes: UInt64,
        volumeUUID: String? = nil
    ) {
        self.mountPoint = mountPoint
        self.isInternal = isInternal
        self.filesystemType = filesystemType
        self.isWritableVolume = isWritableVolume
        self.busProtocol = busProtocol
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.volumeUUID = volumeUUID
    }
}

public protocol DiskInfoProvider: Sendable {
    func diskInfo(for path: String) throws -> VolumeDiskInfo
}

public struct SystemDiskInfoProvider: DiskInfoProvider {
    private let commandRunner: any CommandRunner

    public init(commandRunner: any CommandRunner = SystemCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func diskInfo(for path: String) throws -> VolumeDiskInfo {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let targetPath: String
        if let volumeURL = (try? fileURL.resourceValues(forKeys: [.volumeURLKey]))?.volume {
            targetPath = volumeURL.standardizedFileURL.path
        } else {
            let components = fileURL.pathComponents
            if components.count >= 3 && components[1] == "Volumes" {
                targetPath = "/" + components[1] + "/" + components[2]
            } else {
                targetPath = fileURL.path
            }
        }

        let result = try commandRunner.run(
            "/usr/sbin/diskutil",
            arguments: ["info", "-plist", targetPath]
        )
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/sbin/diskutil",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try Self.parsePlist(result.standardOutput, fallbackPath: targetPath)
    }

    public static func parsePlist(_ plistString: String, fallbackPath: String) throws -> VolumeDiskInfo {
        guard let data = plistString.data(using: .utf8) else {
            throw MacBayError.invalidVolume("Unable to decode diskutil output for \(fallbackPath)")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw MacBayError.invalidVolume("Invalid diskutil plist output for \(fallbackPath)")
        }
        return parse(plist: plist, fallbackPath: fallbackPath)
    }

    public static func parse(plist: [String: Any], fallbackPath: String) -> VolumeDiskInfo {
        let mountPoint = plist["MountPoint"] as? String ?? fallbackPath
        let isInternal = plist["Internal"] as? Bool ?? (fallbackPath == "/")
        let filesystemType = plist["FilesystemType"] as? String ?? ""
        let isWritableVolume = plist["WritableVolume"] as? Bool ?? (plist["Writable"] as? Bool ?? false)
        let busProtocol = plist["BusProtocol"] as? String ?? ""
        let volumeName = plist["VolumeName"] as? String ?? URL(fileURLWithPath: fallbackPath).lastPathComponent
        let totalSize = (plist["TotalSize"] as? NSNumber)?.uint64Value
            ?? (plist["Size"] as? NSNumber)?.uint64Value
            ?? 0
        let availableBytes = (plist["APFSContainerFree"] as? NSNumber)?.uint64Value
            ?? (plist["FreeSpace"] as? NSNumber)?.uint64Value
            ?? 0
        let volumeUUID = plist["VolumeUUID"] as? String

        return VolumeDiskInfo(
            mountPoint: mountPoint,
            isInternal: isInternal,
            filesystemType: filesystemType,
            isWritableVolume: isWritableVolume,
            busProtocol: busProtocol,
            volumeName: volumeName,
            totalBytes: totalSize,
            availableBytes: availableBytes,
            volumeUUID: volumeUUID
        )
    }
}

public enum VolumeSelectionSource: String, Equatable, Sendable {
    case explicit
    case configured
    case autoDetected = "auto_detected"
}

public struct VolumeSelection: Equatable, Sendable {
    public let volume: StorageVolume
    public let source: VolumeSelectionSource
    public let warnings: [String]

    public init(
        volume: StorageVolume,
        source: VolumeSelectionSource,
        warnings: [String] = []
    ) {
        self.volume = volume
        self.source = source
        self.warnings = warnings
    }
}

public enum DefaultVolumeAvailability: Equatable, Sendable {
    case mounted(StorageVolume, pathChanged: Bool)
    case notMounted
    case ineligible(mountPoint: String, reason: String)
}

public struct VolumeManager {
    private let fileManager: FileManager
    public let diskInfoProvider: any DiskInfoProvider
    public let volumeMountPrefix: String

    public init(
        fileManager: FileManager = .default,
        diskInfoProvider: any DiskInfoProvider = SystemDiskInfoProvider(),
        volumeMountPrefix: String = "/Volumes"
    ) {
        self.fileManager = fileManager
        self.diskInfoProvider = diskInfoProvider
        self.volumeMountPrefix = volumeMountPrefix
    }

    public func internalVolume() throws -> StorageVolume {
        let info = try diskInfoProvider.diskInfo(for: "/")
        return StorageVolume(
            name: info.volumeName.isEmpty ? "/" : info.volumeName,
            path: "/",
            isInternal: true,
            totalBytes: info.totalBytes,
            availableBytes: info.availableBytes
        )
    }

    public func eligibilityCheck(for info: VolumeDiskInfo) -> (isEligible: Bool, reason: String?) {
        let prefix = volumeMountPrefix.hasSuffix("/") ? volumeMountPrefix : volumeMountPrefix + "/"
        let cleanMount = volumeMountPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let expectedContainer = "/" + cleanMount
        guard (info.mountPoint.hasPrefix(prefix) || info.mountPoint == expectedContainer) && info.mountPoint != expectedContainer else {
            return (false, "Volume must be mounted under \(expectedContainer)")
        }
        guard !info.isInternal else {
            return (false, "Volume is internal")
        }
        guard info.busProtocol.localizedCaseInsensitiveCompare("Disk Image") != .orderedSame else {
            return (false, "Disk image volumes are not supported")
        }
        guard info.filesystemType.lowercased() == "apfs" else {
            return (false, "Filesystem type is '\(info.filesystemType)', not apfs")
        }
        guard info.isWritableVolume else {
            return (false, "Volume is read-only")
        }
        return (true, nil)
    }

    public func externalVolumesWithWarnings() throws -> (eligible: [StorageVolume], warnings: [String]) {
        let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []

        var eligible: [StorageVolume] = []
        var warnings: [String] = []

        for url in mounted {
            let path = url.standardizedFileURL.path
            if path == "/" { continue }

            do {
                let info = try diskInfoProvider.diskInfo(for: path)
                let check = eligibilityCheck(for: info)
                if check.isEligible {
                    eligible.append(StorageVolume(
                        name: info.volumeName,
                        path: info.mountPoint,
                        isInternal: info.isInternal,
                        totalBytes: info.totalBytes,
                        availableBytes: info.availableBytes
                    ))
                } else if let reason = check.reason {
                    warnings.append("Excluded volume '\(info.volumeName)' (\(info.mountPoint)): \(reason)")
                }
            } catch {
                warnings.append("Excluded volume at \(path): \(error.localizedDescription)")
            }
        }

        eligible.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        warnings.sort()
        return (eligible, warnings)
    }

    public func externalVolumes() throws -> [StorageVolume] {
        try externalVolumesWithWarnings().eligible
    }

    public func diagnosticVolumes() -> (volumes: [VolumeDiskInfo], warnings: [String]) {
        let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []

        let container = URL(fileURLWithPath: volumeMountPrefix).standardizedFileURL.path
        let prefix = container.hasSuffix("/") ? container : container + "/"

        var volumes: [VolumeDiskInfo] = []
        var warnings: [String] = []
        var seenMountPoints: Set<String> = []

        for url in mounted {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix), path != container else {
                continue
            }
            do {
                let info = try diskInfoProvider.diskInfo(for: path)
                guard !info.isInternal else { continue }
                let mountPoint = URL(fileURLWithPath: info.mountPoint).standardizedFileURL.path
                guard mountPoint != container else { continue }
                let key = mountPoint.lowercased()
                guard !seenMountPoints.contains(key) else { continue }
                seenMountPoints.insert(key)
                volumes.append(info)
            } catch {
                warnings.append("Unable to inspect volume at \(path): \(error.localizedDescription)")
            }
        }

        volumes.sort { $0.mountPoint.localizedCaseInsensitiveCompare($1.mountPoint) == .orderedAscending }
        warnings.sort()
        return (volumes, warnings)
    }

    public func resolveExternalVolume(path: String?) throws -> StorageVolume {
        if let path {
            return try explicitVolume(path: path)
        }
        return try autoDetectedExternalVolume()
    }

    public func resolveExternalVolume(
        path: String?,
        configuredDefault: DefaultVolume?
    ) throws -> VolumeSelection {
        if let path {
            return VolumeSelection(volume: try explicitVolume(path: path), source: .explicit)
        }

        guard let configuredDefault else {
            return VolumeSelection(volume: try autoDetectedExternalVolume(), source: .autoDetected)
        }

        switch availability(of: configuredDefault) {
        case let .mounted(volume, pathChanged):
            let warnings = pathChanged
                ? ["Default volume '\(configuredDefault.name)' is mounted at \(volume.path) instead of the saved path \(configuredDefault.path)."]
                : []
            return VolumeSelection(volume: volume, source: .configured, warnings: warnings)
        case .notMounted:
            throw MacBayError.invalidVolume(
                "Configured default volume '\(configuredDefault.name)' (\(configuredDefault.path)) is not mounted. Connect it, pass --volume, or run 'mb init'."
            )
        case let .ineligible(mountPoint, reason):
            throw MacBayError.invalidVolume(
                "Configured default volume '\(configuredDefault.name)' (\(mountPoint)) is not eligible: \(reason). Run 'mb init' to choose another volume."
            )
        }
    }

    public func availability(of defaultVolume: DefaultVolume) -> DefaultVolumeAvailability {
        let infos = mountedVolumeInfos()
        let configuredPath = standardizedPath(defaultVolume.path)
        let pathMatch = infos.first { standardizedPath($0.mountPoint).caseInsensitiveCompare(configuredPath) == .orderedSame }
        let uuidMatch = pathMatch == nil ? uuidMatch(for: defaultVolume, in: infos) : nil

        guard let info = pathMatch ?? uuidMatch else {
            return .notMounted
        }

        let check = eligibilityCheck(for: info)
        guard check.isEligible else {
            return .ineligible(mountPoint: info.mountPoint, reason: check.reason ?? "Volume is not eligible")
        }
        return .mounted(storageVolume(from: info), pathChanged: pathMatch == nil)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func explicitVolume(path: String) throws -> StorageVolume {
        let standardizedPath = MacBayPaths.expandedURL(path).path
        let info = try diskInfoProvider.diskInfo(for: standardizedPath)
        let check = eligibilityCheck(for: info)
        guard check.isEligible else {
            if info.isInternal {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(standardizedPath)")
            } else {
                throw MacBayError.invalidVolume("\(check.reason ?? "Volume is not eligible"): \(standardizedPath)")
            }
        }
        return storageVolume(from: info)
    }

    private func autoDetectedExternalVolume() throws -> StorageVolume {
        let eligibleVolumes = try externalVolumes()
        if eligibleVolumes.isEmpty {
            throw MacBayError.invalidVolume("No eligible external APFS volume was found under /Volumes")
        }
        if eligibleVolumes.count > 1 {
            let names = eligibleVolumes.map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
            throw MacBayError.invalidVolume(
                "Multiple eligible external volumes found: \(names). Specify an external volume with --volume <path>, or run 'mb init' to save a default."
            )
        }
        return eligibleVolumes[0]
    }

    private func uuidMatch(for defaultVolume: DefaultVolume, in infos: [VolumeDiskInfo]) -> VolumeDiskInfo? {
        guard let uuid = defaultVolume.uuid, !uuid.isEmpty else { return nil }
        return infos.first { info in
            guard let mountedUUID = info.volumeUUID, !mountedUUID.isEmpty else { return false }
            return mountedUUID.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    private func mountedVolumeInfos() -> [VolumeDiskInfo] {
        let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []

        var infos: [VolumeDiskInfo] = []
        for url in mounted {
            let path = url.standardizedFileURL.path
            if path == "/" { continue }
            if let info = try? diskInfoProvider.diskInfo(for: path) {
                infos.append(info)
            }
        }
        return infos
    }

    private func storageVolume(from info: VolumeDiskInfo) -> StorageVolume {
        StorageVolume(
            name: info.volumeName,
            path: info.mountPoint,
            isInternal: info.isInternal,
            totalBytes: info.totalBytes,
            availableBytes: info.availableBytes
        )
    }

    public func volume(at url: URL) throws -> StorageVolume {
        let info = try diskInfoProvider.diskInfo(for: url.standardizedFileURL.path)
        return StorageVolume(
            name: info.volumeName,
            path: info.mountPoint,
            isInternal: info.isInternal,
            totalBytes: info.totalBytes,
            availableBytes: info.availableBytes
        )
    }
}
