import Foundation

public struct DeveloperCacheTarget: Equatable, Sendable {
    public let name: String
    public let path: URL

    public init(name: String, path: URL) {
        self.name = name
        self.path = path
    }
}

public struct AppScanner {
    public static let defaultMinimumApplicationSizeBytes: UInt64 = 200 * 1024 * 1024

    private let fileManager: FileManager
    private let sizeCalculator: FileSizeCalculator
    private let appInspector: AppInspector
    private let diskInfoProvider: any DiskInfoProvider
    private let manifestStore: ManifestStore
    private let symlinkResolver: SymlinkResolver

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        appInspector: AppInspector? = nil,
        diskInfoProvider: (any DiskInfoProvider)? = nil,
        manifestStore: ManifestStore? = nil
    ) {
        self.fileManager = fileManager
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.appInspector = appInspector ?? AppInspector(fileManager: fileManager, commandRunner: commandRunner)
        self.diskInfoProvider = diskInfoProvider ?? SystemDiskInfoProvider(commandRunner: commandRunner)
        self.manifestStore = manifestStore ?? ManifestStore(fileManager: fileManager)
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
    }

    public func scan(
        minimumApplicationSizeBytes: UInt64 = AppScanner.defaultMinimumApplicationSizeBytes,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications")],
        developerCacheTargets: [DeveloperCacheTarget] = AppScanner.defaultDeveloperCacheTargets()
    ) -> ScanReport {
        var candidates: [AppCandidate] = []
        var externalApplications: [ExternalApplication] = []
        var unresolvedApplicationLinks: [UnresolvedApplicationLink] = []
        var seenExternalSources: Set<String> = []
        var seenUnresolvedSources: Set<String> = []
        var manifestsByVolume: [String: Result<DockManifest, Error>] = [:]
        var warnings: [String] = []

        for directory in applicationDirectories {
            guard fileManager.fileExists(atPath: directory.path) else {
                warnings.append("Application directory is unavailable: \(directory.path)")
                continue
            }
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                warnings.append("Unable to read \(directory.path): \(error.localizedDescription)")
                continue
            }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                let isSymlink: Bool
                let isDir: Bool
                if let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    isSymlink = values.isSymbolicLink == true
                    isDir = values.isDirectory == true
                } else if let attrs = try? fileManager.attributesOfItem(atPath: entry.path) {
                    isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                    isDir = attrs[.type] as? FileAttributeType == .typeDirectory
                } else {
                    warnings.append("Unable to inspect \(entry.path)")
                    continue
                }

                if isSymlink {
                    let sourcePath = entry.path
                    let sourceKey = entry.standardizedFileURL.path

                    switch symlinkResolver.resolve(at: entry) {
                    case .circular(let targetPath, _):
                        if !seenUnresolvedSources.contains(sourceKey) {
                            seenUnresolvedSources.insert(sourceKey)
                            unresolvedApplicationLinks.append(UnresolvedApplicationLink(
                                name: entry.lastPathComponent,
                                sourcePath: sourcePath,
                                destinationPath: targetPath,
                                reason: "Circular link detected"
                            ))
                        }
                    case .broken(let targetPath, _):
                        if !seenUnresolvedSources.contains(sourceKey) {
                            seenUnresolvedSources.insert(sourceKey)
                            unresolvedApplicationLinks.append(UnresolvedApplicationLink(
                                name: entry.lastPathComponent,
                                sourcePath: sourcePath,
                                destinationPath: targetPath,
                                reason: "Target unavailable"
                            ))
                        }
                    case .resolved(let resolvedURL, _, _):
                        let diskInfo: VolumeDiskInfo
                        do {
                            diskInfo = try diskInfoProvider.diskInfo(for: resolvedURL.path)
                        } catch {
                            if !seenUnresolvedSources.contains(sourceKey) {
                                seenUnresolvedSources.insert(sourceKey)
                                unresolvedApplicationLinks.append(UnresolvedApplicationLink(
                                    name: entry.lastPathComponent,
                                    sourcePath: sourcePath,
                                    destinationPath: resolvedURL.path,
                                    reason: "Volume check failed"
                                ))
                            }
                            continue
                        }

                        let isDiskImage = diskInfo.busProtocol.caseInsensitiveCompare("Disk Image") == .orderedSame
                        if diskInfo.isInternal || isDiskImage {
                            continue
                        }

                        if !seenExternalSources.contains(sourceKey) {
                            seenExternalSources.insert(sourceKey)
                            let targetSize = try? sizeCalculator.size(of: resolvedURL)
                            let volumeURL = URL(fileURLWithPath: diskInfo.mountPoint)

                            let manifestResult: Result<DockManifest, Error>
                            if let cached = manifestsByVolume[volumeURL.path] {
                                manifestResult = cached
                            } else {
                                do {
                                    let loaded = try manifestStore.load(on: volumeURL)
                                    manifestResult = .success(loaded)
                                } catch {
                                    manifestResult = .failure(error)
                                }
                                manifestsByVolume[volumeURL.path] = manifestResult
                            }

                            let managementStatus: ExternalAppManagementStatus
                            switch manifestResult {
                            case .success(let manifest):
                                let isManaged = manifest.items.contains { item in
                                    guard item.kind == .application else { return false }
                                    let itemSource = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                                    let symlinkSource = entry.standardizedFileURL.path
                                    let itemExternal = URL(fileURLWithPath: item.externalPath).standardizedFileURL.path
                                    let resolvedTarget = resolvedURL.standardizedFileURL.path
                                    return itemSource.caseInsensitiveCompare(symlinkSource) == .orderedSame &&
                                           itemExternal.caseInsensitiveCompare(resolvedTarget) == .orderedSame
                                }
                                managementStatus = isManaged ? .macBay : .unmanaged
                            case .failure:
                                managementStatus = .unconfirmed
                            }

                            externalApplications.append(ExternalApplication(
                                name: entry.lastPathComponent,
                                sourcePath: sourcePath,
                                destinationPath: resolvedURL.path,
                                sizeBytes: targetSize,
                                managementStatus: managementStatus
                            ))
                        }
                    }
                } else if isDir {
                    do {
                        let sizeBytes = try sizeCalculator.size(of: entry)
                        if sizeBytes >= minimumApplicationSizeBytes {
                            let compatibility = appInspector.assess(bundleURL: entry)
                            candidates.append(AppCandidate(
                                name: entry.lastPathComponent,
                                path: entry.path,
                                sizeBytes: sizeBytes,
                                kind: .application,
                                compatibility: compatibility
                            ))
                        }
                    } catch {
                        warnings.append("Unable to size \(entry.path): \(error.localizedDescription)")
                    }
                }
            }
        }

        for target in developerCacheTargets {
            guard fileManager.fileExists(atPath: target.path.path) else { continue }
            do {
                let sizeBytes = try sizeCalculator.size(of: target.path)
                if sizeBytes > 0 {
                    candidates.append(AppCandidate(
                        name: target.name,
                        path: target.path.path,
                        sizeBytes: sizeBytes,
                        kind: .developerCache
                    ))
                }
            } catch {
                warnings.append("Unable to size \(target.path.path): \(error.localizedDescription)")
            }
        }

        candidates.sort {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        externalApplications.sort {
            let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
            if cmp == .orderedSame {
                return $0.sourcePath.localizedCaseInsensitiveCompare($1.sourcePath) == .orderedAscending
            }
            return cmp == .orderedAscending
        }

        unresolvedApplicationLinks.sort {
            let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
            if cmp == .orderedSame {
                return $0.sourcePath.localizedCaseInsensitiveCompare($1.sourcePath) == .orderedAscending
            }
            return cmp == .orderedAscending
        }

        return ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: minimumApplicationSizeBytes,
            candidates: candidates,
            externalApplications: externalApplications,
            unresolvedApplicationLinks: unresolvedApplicationLinks,
            warnings: warnings
        )
    }

    public static func defaultDeveloperCacheTargets(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DeveloperCacheTarget] {
        let caches = CacheManager.targets(homeDirectory: homeDirectory).map {
            DeveloperCacheTarget(name: $0.name, path: $0.internalURL)
        }
        return [
            DeveloperCacheTarget(
                name: "Xcode iOS DeviceSupport",
                path: MacBayPaths.defaultXcodeDeviceSupportURL(homeDirectory: homeDirectory)
            ),
            DeveloperCacheTarget(
                name: "Xcode Archives",
                path: MacBayPaths.defaultXcodeArchivesURL(homeDirectory: homeDirectory)
            ),
            DeveloperCacheTarget(
                name: "Xcode DerivedData",
                path: MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory)
            ),
            DeveloperCacheTarget(
                name: "CoreSimulator",
                path: homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator")
            )
        ] + caches
    }
}
