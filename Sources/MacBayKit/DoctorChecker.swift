import Foundation

public struct DoctorChecker {
    private struct ConsultedVolume {
        let info: VolumeDiskInfo
        let manifest: DockManifest?
        let scope: DoctorVolumeScope
    }

    private let fileManager: FileManager
    private let volumeManager: VolumeManager
    private let manifestStore: ManifestStore
    private let symlinkResolver: SymlinkResolver

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        manifestStore: ManifestStore? = nil
    ) {
        self.fileManager = fileManager
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.manifestStore = manifestStore ?? ManifestStore(fileManager: fileManager)
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
    }

    public func check(
        volumePath: String? = nil,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications")],
        developerCacheTargets: [DeveloperCacheTarget] = AppScanner.defaultDeveloperCacheTargets()
    ) throws -> DoctorReport {
        var warnings: [String] = []
        var findings: [DoctorFinding] = []

        let diagnostics = volumeManager.diagnosticVolumes()
        warnings.append(contentsOf: diagnostics.warnings)

        var volumes = diagnostics.volumes
        if let volumePath {
            let requested = MacBayPaths.expandedURL(volumePath).path
            let info: VolumeDiskInfo
            do {
                info = try volumeManager.diskInfoProvider.diskInfo(for: requested)
            } catch {
                throw MacBayError.invalidVolume(
                    "Unable to inspect volume at \(requested): \(error.localizedDescription)"
                )
            }
            guard !info.isInternal else {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(requested)")
            }
            if !volumes.contains(where: { $0.mountPoint.caseInsensitiveCompare(info.mountPoint) == .orderedSame }) {
                volumes.append(info)
            }
        }

        volumes.sort { $0.mountPoint.localizedCaseInsensitiveCompare($1.mountPoint) == .orderedAscending }

        var consulted: [ConsultedVolume] = []
        for info in volumes {
            let volumeURL = URL(fileURLWithPath: info.mountPoint)
            let manifestPath = MacBayPaths.manifestURL(on: volumeURL).path
            let volumeName = info.volumeName.isEmpty
                ? volumeURL.lastPathComponent
                : info.volumeName

            var manifest: DockManifest?
            var manifestStatus: DoctorManifestStatus = .loaded
            do {
                let loaded = try manifestStore.load(on: volumeURL)
                if loaded.version != DockManifest.currentVersion {
                    manifestStatus = .unsupportedVersion
                    findings.append(DoctorFinding(
                        code: .manifestVersionUnsupported,
                        status: .unableToVerify,
                        category: .volume,
                        name: volumeName,
                        paths: [manifestPath],
                        detail: "Manifest version \(loaded.version) is not supported (expected \(DockManifest.currentVersion))",
                        recommendation: "Update MacBay or verify the volume contents manually."
                    ))
                } else if fileManager.fileExists(atPath: manifestPath) {
                    manifestStatus = .loaded
                    manifest = loaded
                } else {
                    manifestStatus = .missing
                    manifest = loaded
                }
            } catch {
                manifestStatus = .unreadable
                warnings.append("Unable to load manifest for \(info.mountPoint): \(error.localizedDescription)")
                findings.append(DoctorFinding(
                    code: .manifestUnreadable,
                    status: .unableToVerify,
                    category: .volume,
                    name: volumeName,
                    paths: [manifestPath],
                    detail: "Manifest could not be read: \(error.localizedDescription)",
                    recommendation: "Inspect or restore \(manifestPath); MacBay does not modify records automatically."
                ))
            }

            consulted.append(ConsultedVolume(
                info: info,
                manifest: manifest,
                scope: DoctorVolumeScope(
                    name: volumeName,
                    mountPoint: info.mountPoint,
                    manifestPath: manifestPath,
                    isReadOnly: !info.isWritableVolume,
                    manifestStatus: manifestStatus,
                    recordCount: manifestStatus == .loaded ? (manifest?.items.count ?? 0) : 0
                )
            ))
        }

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
                findings.append(DoctorFinding(
                    code: .applicationsUnreadable,
                    status: .unableToVerify,
                    category: .applicationLink,
                    name: directory.lastPathComponent,
                    paths: [directory.path],
                    detail: "Unable to read \(directory.path): \(error.localizedDescription)",
                    recommendation: "Check file permissions for \(directory.path)."
                ))
                continue
            }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                if let finding = classifyLink(
                    name: entry.lastPathComponent,
                    sourcePath: entry.path,
                    category: .applicationLink,
                    consulted: consulted
                ) {
                    findings.append(finding)
                }
            }
        }

        for target in developerCacheTargets {
            guard entryExists(at: target.path) else { continue }
            if let finding = classifyLink(
                name: target.name,
                sourcePath: target.path.path,
                category: .developerDataLink,
                consulted: consulted
            ) {
                findings.append(finding)
            }
        }

        for volume in consulted {
            guard let manifest = volume.manifest else { continue }
            for item in manifest.items {
                guard !isSymbolicLink(at: item.sourcePath) else { continue }
                guard !fileManager.fileExists(atPath: item.externalPath) else { continue }
                findings.append(DoctorFinding(
                    code: .recordTargetMissing,
                    status: .needsAttention,
                    category: .record,
                    name: item.name,
                    paths: [item.sourcePath, item.externalPath],
                    detail: "Recorded external copy is missing: \(item.externalPath)",
                    recommendation: "Reconnect the volume or locate the copy; the record and the actual state differ."
                ))
            }
        }

        findings.sort(by: Self.isOrderedBefore)

        let summary = DoctorSummary(
            checked: findings.count,
            healthy: findings.filter { $0.status == .healthy }.count,
            unmanaged: findings.filter { $0.status == .healthy && $0.managed == false }.count,
            needsAttention: findings.filter { $0.status == .needsAttention }.count,
            unableToVerify: findings.filter { $0.status == .unableToVerify }.count
        )

        return DoctorReport(
            generatedAt: macBayTimestamp(),
            volumes: consulted.map(\.scope),
            findings: findings,
            summary: summary,
            warnings: warnings
        )
    }

    private func classifyLink(
        name: String,
        sourcePath: String,
        category: DoctorCategory,
        consulted: [ConsultedVolume]
    ) -> DoctorFinding? {
        guard isSymbolicLink(at: sourcePath) else {
            guard !fileManager.fileExists(atPath: sourcePath) else { return nil }
            return DoctorFinding(
                code: .linkUnreadable,
                status: .unableToVerify,
                category: category,
                name: name,
                paths: [sourcePath],
                detail: "Unable to inspect link: \(sourcePath)",
                recommendation: "Check file permissions for \(sourcePath)."
            )
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let standardizedSource = sourceURL.standardizedFileURL.path

        switch symlinkResolver.resolve(at: sourceURL) {
        case let .broken(targetPath, _):
            return DoctorFinding(
                code: .linkTargetUnavailable,
                status: .needsAttention,
                category: category,
                name: name,
                paths: [sourcePath, targetPath],
                detail: "Target unavailable: \(targetPath)",
                recommendation: "Reconnect the volume or confirm the path exists, then run 'mb doctor' again."
            )

        case let .circular(targetPath, _):
            return DoctorFinding(
                code: .linkCircular,
                status: .needsAttention,
                category: category,
                name: name,
                paths: [sourcePath, targetPath],
                detail: "Circular link detected: \(targetPath)",
                recommendation: "Repoint the link to the external copy or remove it manually."
            )

        case let .resolved(target, hops, usesRelativeDestination):
            let note = Self.linkNote(hops: hops, usesRelativeDestination: usesRelativeDestination)
            let info: VolumeDiskInfo
            do {
                info = try volumeManager.diskInfoProvider.diskInfo(for: target.path)
            } catch {
                return DoctorFinding(
                    code: .linkTargetUnverified,
                    status: .unableToVerify,
                    category: category,
                    name: name,
                    paths: [sourcePath, target.path],
                    detail: "Volume check failed for \(target.path)\(note)",
                    recommendation: "Confirm the volume is mounted and reachable, then run 'mb doctor' again."
                )
            }

            let standardizedTarget = target.standardizedFileURL.path
            if info.isInternal {
                return DoctorFinding(
                    code: .linkUnmanaged,
                    status: .healthy,
                    category: category,
                    name: name,
                    paths: [sourcePath, standardizedTarget],
                    detail: "No MacBay record for this link; target is on an internal volume\(note)",
                    recommendation: "",
                    managed: false
                )
            }

            var matchedRecord: DockedItem?
            var mismatchedRecord: DockedItem?
            for volume in consulted {
                for item in volume.manifest?.items ?? [] {
                    let itemSource = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                    guard itemSource.caseInsensitiveCompare(standardizedSource) == .orderedSame else { continue }
                    let itemExternal = URL(fileURLWithPath: item.externalPath).standardizedFileURL.path
                    if itemExternal.caseInsensitiveCompare(standardizedTarget) == .orderedSame {
                        matchedRecord = item
                    } else {
                        mismatchedRecord = item
                    }
                }
            }

            if matchedRecord != nil {
                return DoctorFinding(
                    code: .linkManagedRecord,
                    status: .healthy,
                    category: category,
                    name: name,
                    paths: [sourcePath, standardizedTarget],
                    detail: "Managed by MacBay, record matches\(note)",
                    recommendation: "",
                    managed: true
                )
            }

            if let record = mismatchedRecord {
                return DoctorFinding(
                    code: .linkRecordMismatch,
                    status: .needsAttention,
                    category: category,
                    name: name,
                    paths: [sourcePath, standardizedTarget, record.externalPath],
                    detail: "Link resolves to \(standardizedTarget) but the record points to \(record.externalPath)\(note)",
                    recommendation: "Verify which copy is authoritative; MacBay does not change links automatically."
                )
            }

            if isMacBayLayoutPath(standardizedTarget, on: info.mountPoint) {
                return DoctorFinding(
                    code: .linkManagedLayout,
                    status: .healthy,
                    category: category,
                    name: name,
                    paths: [sourcePath, standardizedTarget],
                    detail: "Matches the MacBay external layout\(note)",
                    recommendation: "",
                    managed: true
                )
            }

            return DoctorFinding(
                code: .linkUnmanaged,
                status: .healthy,
                category: category,
                name: name,
                paths: [sourcePath, standardizedTarget],
                detail: "No MacBay record for this link\(note)",
                recommendation: "",
                managed: false
            )
        }
    }

    private func isMacBayLayoutPath(_ path: String, on mountPoint: String) -> Bool {
        let volumeURL = URL(fileURLWithPath: mountPoint)
        let roots = [
            MacBayPaths.applicationsRoot(on: volumeURL),
            MacBayPaths.xcodeRoot(on: volumeURL),
            MacBayPaths.cachesRoot(on: volumeURL)
        ]
        return roots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    private func entryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(at: url.path)
    }

    private func isSymbolicLink(at path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func linkNote(hops: Int, usesRelativeDestination: Bool) -> String {
        var parts: [String] = []
        if usesRelativeDestination {
            parts.append("relative link")
        }
        if hops > 1 {
            parts.append("\(hops) hops")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func isOrderedBefore(_ lhs: DoctorFinding, _ rhs: DoctorFinding) -> Bool {
        let lhsRank = (statusRank(lhs.status), categoryRank(lhs.category))
        let rhsRank = (statusRank(rhs.status), categoryRank(rhs.category))
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return (lhs.paths.first ?? "").localizedCaseInsensitiveCompare(rhs.paths.first ?? "") == .orderedAscending
    }

    private static func statusRank(_ status: DoctorStatus) -> Int {
        switch status {
        case .needsAttention: return 0
        case .unableToVerify: return 1
        case .healthy: return 2
        }
    }

    private static func categoryRank(_ category: DoctorCategory) -> Int {
        switch category {
        case .applicationLink: return 0
        case .developerDataLink: return 1
        case .record: return 2
        case .volume: return 3
        }
    }
}
