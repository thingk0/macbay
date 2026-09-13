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
    private let configStore: ConfigStore
    private let symlinkResolver: SymlinkResolver
    private let sizeCalculator: FileSizeCalculator
    private let operationJournal: OperationJournal
    private let operationLock: any VolumeOperationLocking

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        manifestStore: ManifestStore? = nil,
        configStore: ConfigStore? = nil,
        operationLock: any VolumeOperationLocking = VolumeOperationLock()
    ) {
        self.fileManager = fileManager
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.manifestStore = manifestStore ?? ManifestStore(fileManager: fileManager)
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.operationJournal = OperationJournal(fileManager: fileManager)
        self.operationLock = operationLock
        self.repairJournal = DarwinRepairJournal(fileManager: fileManager)
    }

    private let repairJournal: any RepairJournaling


    public func check(
        volumePath: String? = nil,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications")],
        developerCacheTargets: [DeveloperCacheTarget] = AppScanner.defaultDeveloperCacheTargets(),
        fix: Bool = false,
        dryRun: Bool = false
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

        let config: MacBayConfig?
        do {
            config = try configStore.load()
        } catch {
            config = nil
            findings.append(DoctorFinding(
                code: .configUnreadable,
                status: .unableToVerify,
                category: .volume,
                name: "MacBay configuration",
                paths: [configStore.configURL.path],
                detail: "Configuration could not be read: \(error.localizedDescription)",
                recommendation: "Repair or remove \(configStore.configURL.path), then run 'mb init' to save a default volume."
            ))
        }

        if let configured = config?.defaultVolume {
            switch volumeManager.availability(of: configured) {
            case let .mounted(volume, pathChanged):
                findings.append(DoctorFinding(
                    code: .defaultVolumeMounted,
                    status: .healthy,
                    category: .volume,
                    name: configured.name,
                    paths: [volume.path],
                    detail: pathChanged
                        ? "Default volume is mounted at \(volume.path); the saved path was \(configured.path)"
                        : "Default volume is mounted at \(volume.path)",
                    recommendation: ""
                ))
            case .notMounted:
                findings.append(DoctorFinding(
                    code: .defaultVolumeUnavailable,
                    status: .needsAttention,
                    category: .volume,
                    name: configured.name,
                    paths: [configured.path],
                    detail: "Default volume is not mounted",
                    recommendation: "Run 'mb init' to update the default volume."
                ))
            case let .ineligible(mountPoint, reason):
                findings.append(DoctorFinding(
                    code: .defaultVolumeIneligible,
                    status: .needsAttention,
                    category: .volume,
                    name: configured.name,
                    paths: [mountPoint],
                    detail: "Default volume is not eligible: \(reason)",
                    recommendation: "Run 'mb init' to update the default volume."
                ))
            }
        }

        var classifiedSources = Set<String>()

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
                classifiedSources.insert(entry.standardizedFileURL.path)
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
            classifiedSources.insert(target.path.standardizedFileURL.path)
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
                let sourceKey = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                guard !isSymbolicLink(at: item.sourcePath) else {
                    // /Applications 앱과 알려진 캐시는 위에서 이미 검사했다. 임의 디렉터리는
                    // 여기서 링크를 검사해야 깨진 링크·기록 불일치를 잡을 수 있다.
                    guard item.kind != .application, !classifiedSources.contains(sourceKey) else { continue }
                    classifiedSources.insert(sourceKey)
                    if let finding = classifyLink(
                        name: item.name,
                        sourcePath: item.sourcePath,
                        category: item.kind == .directory ? .dataLink : .developerDataLink,
                        consulted: consulted
                    ) {
                        findings.append(finding)
                    }
                    continue
                }
                findings.append(inspectRecord(item))
            }

            let volumeURL = URL(fileURLWithPath: volume.info.mountPoint)
            let incomplete = operationJournal.listIncompleteOperations(on: volumeURL)
            for record in incomplete {
                findings.append(DoctorFinding(
                    code: .incompleteOperation,
                    status: .needsAttention,
                    category: .applicationLink,
                    name: record.appName,
                    paths: [record.sourcePath, record.targetExternalPath, record.originalExternalPath],
                    detail: "Incomplete adopt operation detected for \(record.appName) (interrupted at phase: \(record.phase.rawValue))",
                    recommendation: "Run 'mb adopt \"\(record.appName)\"' to complete adoption, or inspect the paths manually."
                ))
            }

            let incompleteRepair = repairJournal.listIncomplete(on: volumeURL)
            for record in incompleteRepair {
                findings.append(DoctorFinding(
                    code: .incompleteOperation,
                    status: .needsAttention,
                    category: .applicationLink,
                    name: record.appName,
                    paths: [record.localPath, record.externalPath, record.backupPath],
                    detail: "Incomplete repair operation detected for \(record.appName) (interrupted at phase: \(record.phase.rawValue))",
                    recommendation: "Run 'mb repair \"\(record.appName)\" --rollback' to restore, or inspect the paths manually."
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

        var report = DoctorReport(
            generatedAt: macBayTimestamp(),
            volumes: consulted.map(\.scope),
            findings: findings,
            summary: summary,
            warnings: warnings,
            notes: notes(for: consulted)
        )

        guard fix else { return report }
        let fixes = applyFixes(findings: findings, consulted: consulted, dryRun: dryRun)
        guard !dryRun, fixes.contains(where: { $0.status == .fixed }) else {
            return report.withFixes(fixes)
        }
        // Re-scan so the report reflects the post-fix state, then attach the fixes.
        report = try check(
            volumePath: volumePath,
            applicationDirectories: applicationDirectories,
            developerCacheTargets: developerCacheTargets
        )
        return report.withFixes(fixes)
    }

    /// 'mb doctor --fix' can repair only the cases where the manifest already says
    /// what the correct state is: a link whose recorded external copy exists can be
    /// repointed without guessing. Everything else stays manual.
    private func applyFixes(
        findings: [DoctorFinding],
        consulted: [ConsultedVolume],
        dryRun: Bool
    ) -> [DoctorFix] {
        var fixes: [DoctorFix] = []
        for finding in findings where finding.status == .needsAttention {
            switch finding.code {
            case .linkTargetUnavailable, .linkCircular:
                fixes.append(fixUnreachableLink(finding, consulted: consulted, dryRun: dryRun))
            default:
                fixes.append(DoctorFix(
                    code: finding.code,
                    name: finding.name,
                    paths: finding.paths,
                    status: .skipped,
                    detail: "No automatic fix is available; follow the recommendation for this finding."
                ))
            }
        }
        return fixes
    }

    /// link_target_unavailable / link_circular: the link is unusable, a manifest record
    /// exists for the source, and the recorded copy exists — repoint the link to it.
    private func fixUnreachableLink(
        _ finding: DoctorFinding,
        consulted: [ConsultedVolume],
        dryRun: Bool
    ) -> DoctorFix {
        let source = finding.paths.first ?? ""
        // The same source may have stale records on more than one volume; only
        // a single live recorded copy makes the correct target unambiguous.
        let candidates = recordedItems(forSourcePath: source, in: consulted).filter {
            fileManager.fileExists(atPath: $0.item.externalPath)
                && isUnderManagedRoot($0.item.externalPath, onMountPoint: $0.mountPoint)
        }
        guard let match = candidates.first else {
            return DoctorFix(
                code: finding.code, name: finding.name, paths: finding.paths,
                status: .skipped,
                detail: "No MacBay record with a live external copy for this link; reconnect the volume or relocate the copy manually."
            )
        }
        guard candidates.count == 1 else {
            return DoctorFix(
                code: finding.code, name: finding.name, paths: finding.paths,
                status: .skipped,
                detail: "Multiple records claim this source (\(candidates.map { $0.item.externalPath }.joined(separator: ", "))); resolve the duplicate records first."
            )
        }
        guard !dryRun else {
            return DoctorFix(
                code: finding.code, name: finding.name, paths: finding.paths,
                status: .planned,
                detail: "Would repoint the link at \(source) -> \(match.item.externalPath)"
            )
        }
        do {
            return try operationLock.withVolumeLock(on: URL(fileURLWithPath: match.mountPoint)) {
                // Re-check inside the lock: the path must still be a link, not
                // data that replaced it between the scan and the fix.
                guard isSymbolicLink(at: source) else {
                    return DoctorFix(
                        code: finding.code, name: finding.name, paths: finding.paths,
                        status: .skipped,
                        detail: "The path at \(source) is no longer a link; leaving it untouched."
                    )
                }
                try fileManager.removeItem(at: URL(fileURLWithPath: source))
                try fileManager.createSymbolicLink(atPath: source, withDestinationPath: match.item.externalPath)
                return DoctorFix(
                    code: finding.code, name: finding.name, paths: finding.paths,
                    status: .fixed,
                    detail: "Repointed the link to the recorded copy at \(match.item.externalPath)"
                )
            }
        } catch {
            return DoctorFix(
                code: finding.code, name: finding.name, paths: finding.paths,
                status: .failed,
                detail: "Could not repoint the link: \(error.localizedDescription)"
            )
        }
    }

    private func recordedItems(
        forSourcePath sourcePath: String,
        in consulted: [ConsultedVolume]
    ) -> [(item: DockedItem, mountPoint: String)] {
        let standardized = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        var matches: [(item: DockedItem, mountPoint: String)] = []
        for volume in consulted {
            for item in volume.manifest?.items ?? [] {
                let itemSource = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                if itemSource.caseInsensitiveCompare(standardized) == .orderedSame {
                    matches.append((item, volume.info.mountPoint))
                }
            }
        }
        return matches
    }

    /// Links are only ever repointed to paths inside a volume's MacBay layout,
    /// so a hand-edited record cannot redirect a link to an arbitrary path.
    private func isUnderManagedRoot(_ path: String, onMountPoint mountPoint: String?) -> Bool {
        guard let mountPoint else { return false }
        let root = MacBayPaths.externalRoot(on: URL(fileURLWithPath: mountPoint)).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root + "/")
    }

    private func inspectRecord(_ item: DockedItem) -> DoctorFinding {
        let sourceURL = URL(fileURLWithPath: item.sourcePath)
        let externalURL = URL(fileURLWithPath: item.externalPath)
        let localExists = fileManager.fileExists(atPath: item.sourcePath)
        let externalExists = fileManager.fileExists(atPath: item.externalPath)

        if localExists && externalExists {
            let localSize = try? sizeCalculator.size(of: sourceURL)
            let externalSize = try? sizeCalculator.size(of: externalURL)
            return DoctorFinding(
                code: .localDataDetected,
                status: .needsAttention,
                category: .record,
                name: item.name,
                paths: [item.sourcePath, item.externalPath],
                detail: "Local data detected at \(item.sourcePath)\(Self.sizeNote(localSize)); recorded copy exists at \(item.externalPath)\(Self.sizeNote(externalSize))",
                recommendation: "Compare the two copies with 'mb repair \"\(item.name)\"'; MacBay does not delete, overwrite, or re-move anything.",
                localSizeBytes: localSize,
                externalSizeBytes: externalSize
            )
        }

        if !localExists && externalExists {
            let externalSize = try? sizeCalculator.size(of: externalURL)
            return DoctorFinding(
                code: .recordSourceMissing,
                status: .needsAttention,
                category: .record,
                name: item.name,
                paths: [item.sourcePath, item.externalPath],
                detail: "Recorded source path is missing: \(item.sourcePath); the recorded copy exists at \(item.externalPath)\(Self.sizeNote(externalSize))",
                recommendation: "Confirm whether the item was removed intentionally; MacBay does not change records automatically.",
                externalSizeBytes: externalSize
            )
        }

        var detail = "Recorded external copy is missing: \(item.externalPath)"
        var localSize: UInt64?
        if localExists {
            localSize = try? sizeCalculator.size(of: sourceURL)
            detail += "; local data is present at \(item.sourcePath)\(Self.sizeNote(localSize))"
        } else {
            detail += "; the recorded source path is also missing: \(item.sourcePath)"
        }
        return DoctorFinding(
            code: .recordTargetMissing,
            status: .needsAttention,
            category: .record,
            name: item.name,
            paths: [item.sourcePath, item.externalPath],
            detail: detail,
            recommendation: "Reconnect the volume or locate the copy; the record and the actual state differ.",
            localSizeBytes: localSize
        )
    }

    private func notes(for consulted: [ConsultedVolume]) -> [String] {
        var notes: [String] = []

        if consulted.isEmpty {
            notes.append("No external volumes were consulted, so recorded items could not be checked.")
        } else {
            notes.append("Local data checks cover items recorded in MacBay manifests; manually relocated items have no MacBay history and are not evaluated.")
        }

        for volume in consulted where volume.manifest == nil {
            notes.append("Recorded items on '\(volume.scope.name)' (\(volume.scope.mountPoint)) were not checked because its manifest could not be read.")
        }

        return notes
    }

    private static func sizeNote(_ sizeBytes: UInt64?) -> String {
        guard let sizeBytes else { return "" }
        return " (\(OutputFormatter.humanBytes(sizeBytes)))"
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
            MacBayPaths.cachesRoot(on: volumeURL),
            MacBayPaths.dataRoot(on: volumeURL)
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
        case .dataLink: return 1
        case .record: return 2
        case .externalReference: return 3
        case .volume: return 4
        @unknown default: return 5
        }
    }
}

extension DoctorCode {
    /// Codes 'mb doctor --fix' can repair on its own: in each case the manifest
    /// record is authoritative and the correct link state is unambiguous.
    /// record_source_missing stays manual — a deleted source link is often
    /// intentional, so recreating it silently would resurrect removed items.
    /// Findings that need a judgment call (data conflicts, missing copies,
    /// volume problems) are never auto-fixed.
    public var isAutoFixable: Bool {
        switch self {
        case .linkTargetUnavailable, .linkCircular:
            return true
        default:
            return false
        }
    }
}
