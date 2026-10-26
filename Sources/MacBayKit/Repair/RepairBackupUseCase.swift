import Foundation

public struct RepairBackupUseCase: RepairBackupUseCaseProtocol, @unchecked Sendable {
    private struct ScanResult {
        let entries: [RepairBackupEntry]
        let notes: [String]
        let warnings: [String]
    }

    private let fileSystem: any RepairBackupFileSystem
    private let operationLock: any VolumeOperationLocking

    public init(
        fileSystem: any RepairBackupFileSystem = DarwinRepairBackupFileSystem(),
        operationLock: any VolumeOperationLocking = VolumeOperationLock()
    ) {
        self.fileSystem = fileSystem
        self.operationLock = operationLock
    }

    public func inventory(on volume: URL, volumeName: String) throws -> RepairBackupInventory {
        let scan = scanBackups(on: volume)
        return inventory(from: scan, on: volume, volumeName: volumeName)
    }

    public func planRemoval(
        ids: [String],
        on volume: URL,
        volumeName: String
    ) throws -> RepairBackupRemovalPlan {
        let scan = scanBackups(on: volume)
        var selected: [RepairBackupEntry] = []
        var refused: [RepairBackupRemovalRefusal] = []
        var handledIDs: Set<String> = []
        var refusedTokens: Set<String> = []

        for rawID in ids {
            let token = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenKey = token.lowercased()
            guard !token.isEmpty else {
                if refusedTokens.insert(tokenKey).inserted {
                    refused.append(RepairBackupRemovalRefusal(id: rawID, reason: "Backup ID is empty."))
                }
                continue
            }
            guard !token.contains("/") else {
                if refusedTokens.insert(tokenKey).inserted {
                    refused.append(RepairBackupRemovalRefusal(
                        id: rawID,
                        reason: "Backup IDs are operation directory names, not paths."
                    ))
                }
                continue
            }

            let matches = resolve(token: token, in: scan.entries)
            switch matches {
            case .none:
                if refusedTokens.insert(tokenKey).inserted {
                    refused.append(RepairBackupRemovalRefusal(
                        id: rawID,
                        reason: "No backup with this operation ID was found on the volume."
                    ))
                }
            case .ambiguous(let count):
                if refusedTokens.insert(tokenKey).inserted {
                    refused.append(RepairBackupRemovalRefusal(
                        id: rawID,
                        reason: "The ID prefix matches \(count) backups; use more characters."
                    ))
                }
            case .entry(let entry):
                guard handledIDs.insert(entry.id).inserted else { continue }
                switch entry.state {
                case .unreferenced:
                    selected.append(entry)
                case .referenced:
                    refused.append(RepairBackupRemovalRefusal(
                        id: entry.id,
                        appName: entry.appName,
                        path: entry.path,
                        reason: "Referenced by \(entry.referencedBy ?? "an operation or recovery journal"); it cannot be removed."
                    ))
                case .unverifiable:
                    refused.append(RepairBackupRemovalRefusal(
                        id: entry.id,
                        appName: entry.appName,
                        path: entry.path,
                        reason: entry.reason ?? "The backup could not be verified; it cannot be removed."
                    ))
                }
            }
        }

        return RepairBackupRemovalPlan(
            generatedAt: macBayTimestamp(),
            volumeName: volumeName,
            volumePath: volume.path,
            requestedIDs: ids,
            selected: selected,
            refused: refused,
            totalBytes: selected.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
            notes: removalNotes
        )
    }

    public func execute(
        plan: RepairBackupRemovalPlan,
        progress: ProgressHandler? = nil
    ) throws -> RepairBackupRemovalResult {
        let volume = URL(fileURLWithPath: plan.volumePath)
        return try operationLock.withVolumeLock(on: volume) {
            let freeBytesBefore = try? fileSystem.availableBytes(on: volume)
            guard !plan.selected.isEmpty else {
                return RepairBackupRemovalResult(
                    generatedAt: macBayTimestamp(),
                    volumeName: plan.volumeName,
                    volumePath: plan.volumePath,
                    removed: [],
                    refused: plan.refused,
                    failed: [],
                    reclaimedBytes: 0,
                    freeBytesBefore: freeBytesBefore,
                    freeBytesAfter: freeBytesBefore,
                    notes: plan.notes + ["No backups were removed."]
                )
            }

            let scan = scanBackups(on: volume)
            let currentEntries = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.id, $0) })
            var removed: [RepairBackupEntry] = []
            var failed: [RepairBackupRemovalFailure] = []
            var notes = plan.notes

            for planned in plan.selected {
                guard let current = currentEntries[planned.id] else {
                    failed.append(RepairBackupRemovalFailure(
                        id: planned.id,
                        appName: planned.appName,
                        path: planned.path,
                        reason: "The backup no longer exists. Run 'mb backups' again."
                    ))
                    continue
                }

                guard current.state == .unreferenced else {
                    failed.append(RepairBackupRemovalFailure(
                        id: current.id,
                        appName: current.appName,
                        path: current.path,
                        reason: current.state == .referenced
                            ? "The backup is now referenced by \(current.referencedBy ?? "an operation or recovery journal")."
                            : "The backup is no longer verifiable: \(current.reason ?? "unknown reason")."
                    ))
                    continue
                }

                guard current.path == planned.path,
                      current.sizeBytes == planned.sizeBytes,
                      current.savedAt == planned.savedAt else {
                    failed.append(RepairBackupRemovalFailure(
                        id: current.id,
                        appName: current.appName,
                        path: current.path,
                        reason: "The backup changed since the preview. Run 'mb backups' again."
                    ))
                    continue
                }

                if let reason = unsafeRemovalReason(for: current, on: volume) {
                    failed.append(RepairBackupRemovalFailure(
                        id: current.id,
                        appName: current.appName,
                        path: current.path,
                        reason: "\(reason) No files were changed for this backup."
                    ))
                    continue
                }

                progress?(.removingBackup)
                do {
                    try fileSystem.removeItem(at: URL(fileURLWithPath: current.path))
                    let operationDirectory = URL(fileURLWithPath: current.path).deletingLastPathComponent()
                    if fileSystem.kind(of: operationDirectory) == .directory {
                        if (try? fileSystem.isDirectoryEmpty(at: operationDirectory)) == true {
                            do {
                                try fileSystem.removeItem(at: operationDirectory)
                            } catch {
                                notes.append(
                                    "Removed the backup but could not remove the empty operation directory \(operationDirectory.path): \(error.localizedDescription)"
                                )
                            }
                        } else {
                            notes.append(
                                "Kept \(operationDirectory.path) because it contains items other than the removed backup."
                            )
                        }
                    } else {
                        notes.append(
                            "Removed the backup but left \(operationDirectory.path) because it is no longer a readable directory."
                        )
                    }
                    removed.append(current)
                } catch {
                    failed.append(RepairBackupRemovalFailure(
                        id: current.id,
                        appName: current.appName,
                        path: current.path,
                        reason: error.localizedDescription
                    ))
                }
            }

            let freeBytesAfter = try? fileSystem.availableBytes(on: volume)
            if removed.isEmpty {
                notes.append("No backups were removed.")
            }

            return RepairBackupRemovalResult(
                generatedAt: macBayTimestamp(),
                volumeName: plan.volumeName,
                volumePath: plan.volumePath,
                removed: removed,
                refused: plan.refused,
                failed: failed,
                reclaimedBytes: removed.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
                freeBytesBefore: freeBytesBefore,
                freeBytesAfter: freeBytesAfter,
                notes: notes
            )
        }
    }

    private enum Resolution {
        case entry(RepairBackupEntry)
        case ambiguous(count: Int)
        case none
    }

    private func resolve(token: String, in entries: [RepairBackupEntry]) -> Resolution {
        let lowered = token.lowercased()
        let exact = entries.filter { $0.id.lowercased() == lowered }
        if exact.count == 1 {
            return .entry(exact[0])
        }
        let prefixed = entries.filter { $0.id.lowercased().hasPrefix(lowered) }
        if prefixed.count == 1 {
            return .entry(prefixed[0])
        }
        if prefixed.count > 1 {
            return .ambiguous(count: prefixed.count)
        }
        return .none
    }

    private func scanBackups(on volume: URL) -> ScanResult {
        let root = MacBayPaths.backupsRoot(on: volume)
        var notes = [String]()
        var warnings = [String]()

        switch fileSystem.kind(of: root) {
        case .missing:
            return ScanResult(
                entries: [],
                notes: ["No repair backups were found at \(root.path)."],
                warnings: []
            )
        case .symbolicLink:
            return ScanResult(
                entries: [],
                notes: [],
                warnings: ["The backups root \(root.path) is a symbolic link and was not followed."]
            )
        case .file, .unreadable:
            return ScanResult(
                entries: [],
                notes: [],
                warnings: ["The backups root \(root.path) is not a readable directory and was not inspected."]
            )
        case .directory:
            break
        }

        let journalScan = fileSystem.journalFiles(on: volume)
        warnings.append(contentsOf: journalScan.warnings)
        let hasUnreadableJournals = journalScan.files.contains { file in
            guard let contents = file.contents else { return true }
            return !Self.isValidJSON(contents)
        }
        if hasUnreadableJournals {
            warnings.append(
                "Some operation journals could not be read or parsed; backups without a confirmed reference are treated as unverifiable and protected."
            )
        }

        let children: [URL]
        do {
            children = try fileSystem.directoryEntries(at: root)
        } catch {
            warnings.append("The backups root \(root.path) could not be read: \(error.localizedDescription)")
            return ScanResult(entries: [], notes: notes, warnings: warnings)
        }

        var entries: [RepairBackupEntry] = []
        for child in children.sorted(by: { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }) {
            guard isContained(child, in: root) else {
                warnings.append("Skipped a backup entry outside the managed backups root: \(child.path)")
                continue
            }
            entries.append(contentsOf: inspectOperationDirectory(
                child,
                root: root,
                journalScan: journalScan,
                hasUnreadableJournals: hasUnreadableJournals
            ))
        }

        entries.sort(by: Self.isOrderedBefore)

        if entries.isEmpty {
            notes.append("No repair backups were found at \(root.path).")
        }
        notes.append("Repair backups are never deleted automatically; remove only the operation IDs you no longer need.")
        notes.append("Sizes are logical; APFS shared blocks and snapshots can change the actual free space.")

        return ScanResult(entries: entries, notes: notes, warnings: warnings)
    }

    private func inspectOperationDirectory(
        _ operationDirectory: URL,
        root: URL,
        journalScan: RepairBackupJournalScan,
        hasUnreadableJournals: Bool
    ) -> [RepairBackupEntry] {
        let id = operationDirectory.lastPathComponent
        guard isContained(operationDirectory, in: root) else {
            return [unverifiableEntry(
                id: id,
                appName: id,
                path: operationDirectory.path,
                reason: "The operation directory is outside the managed backups root."
            )]
        }

        switch fileSystem.kind(of: operationDirectory) {
        case .symbolicLink:
            return [unverifiableEntry(
                id: id,
                appName: id,
                path: operationDirectory.path,
                reason: "The operation directory is a symbolic link and was not followed."
            )]
        case .file, .unreadable, .missing:
            return [unverifiableEntry(
                id: id,
                appName: id,
                path: operationDirectory.path,
                reason: "The operation directory is not a readable directory."
            )]
        case .directory:
            break
        }

        let children: [URL]
        do {
            children = try fileSystem.directoryEntries(at: operationDirectory)
        } catch {
            return [unverifiableEntry(
                id: id,
                appName: id,
                path: operationDirectory.path,
                reason: "The operation directory could not be read: \(error.localizedDescription)"
            )]
        }

        let appBundles = children
            .filter { !Self.isIgnorableMetadata($0) }
            .filter { $0.lastPathComponent.hasSuffix(".app") }
        let meaningfulChildren = children.filter { !Self.isIgnorableMetadata($0) }
        guard meaningfulChildren.count == 1, let bundle = appBundles.first else {
            let appName = meaningfulChildren.count == 1
                ? meaningfulChildren[0].lastPathComponent
                : operationDirectory.lastPathComponent
            return [unverifiableEntry(
                id: id,
                appName: appName,
                path: operationDirectory.path,
                reason: "Unrecognized backup layout: expected exactly one .app bundle."
            )]
        }

        guard isContained(bundle, in: root) else {
            return [unverifiableEntry(
                id: id,
                appName: bundle.lastPathComponent,
                path: bundle.path,
                reason: "The backup bundle is outside the managed backups root."
            )]
        }

        switch fileSystem.kind(of: bundle) {
        case .directory:
            break
        case .symbolicLink:
            return [unverifiableEntry(
                id: id,
                appName: bundle.lastPathComponent,
                path: bundle.path,
                reason: "The backup bundle is a symbolic link and was not followed."
            )]
        case .file, .missing, .unreadable:
            return [unverifiableEntry(
                id: id,
                appName: bundle.lastPathComponent,
                path: bundle.path,
                reason: "The backup bundle is not a readable directory."
            )]
        }

        let metadata = fileSystem.bundleMetadata(at: bundle)
        let savedAt = fileSystem.creationDate(of: operationDirectory).map(Self.iso8601String)
        let sizeBytes = try? fileSystem.size(of: bundle)
        let referencedBy = referencedJournal(for: bundle.path, id: id, in: journalScan.files)

        let state: RepairBackupState
        let reason: String?
        if !metadata.isVerifiable {
            state = .unverifiable
            reason = metadata.reason
        } else if sizeBytes == nil {
            state = .unverifiable
            reason = "The backup size could not be read."
        } else if savedAt == nil {
            state = .unverifiable
            reason = "The backup date could not be read."
        } else if referencedBy != nil {
            state = .referenced
            reason = nil
        } else if !journalScan.isComplete || hasUnreadableJournals {
            state = .unverifiable
            reason = "An operation journal could not be read, so a reference to this backup cannot be ruled out."
        } else {
            state = .unreferenced
            reason = nil
        }

        return [RepairBackupEntry(
            id: id,
            appName: bundle.lastPathComponent,
            path: bundle.path,
            version: metadata.version,
            buildNumber: metadata.buildNumber,
            savedAt: savedAt,
            sizeBytes: sizeBytes,
            state: state,
            referencedBy: referencedBy,
            reason: reason
        )]
    }

    private func unverifiableEntry(id: String, appName: String, path: String, reason: String) -> RepairBackupEntry {
        RepairBackupEntry(
            id: id,
            appName: appName,
            path: path,
            version: nil,
            buildNumber: nil,
            savedAt: nil,
            sizeBytes: nil,
            state: .unverifiable,
            referencedBy: nil,
            reason: reason
        )
    }

    private func referencedJournal(
        for backupPath: String,
        id: String,
        in journals: [RepairBackupJournalFile]
    ) -> String? {
        let marker = "/Backups/\(id)/"
        for journal in journals {
            guard let contents = journal.contents else { continue }
            let normalized = contents.replacingOccurrences(of: "\\/", with: "/")
            let pathMatch = normalized.range(of: backupPath, options: .caseInsensitive) != nil
            let idMatch = normalized.range(of: marker, options: .caseInsensitive) != nil
            if pathMatch || idMatch {
                return journal.path
            }
        }
        return nil
    }

    private func inventory(
        from scan: ScanResult,
        on volume: URL,
        volumeName: String
    ) -> RepairBackupInventory {
        let backups = scan.entries
        return RepairBackupInventory(
            generatedAt: macBayTimestamp(),
            volumeName: volumeName,
            volumePath: volume.path,
            backupsRoot: MacBayPaths.backupsRoot(on: volume).path,
            backups: backups,
            summary: RepairBackupSummary(
                count: backups.count,
                totalSizeBytes: backups.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
                referencedCount: backups.filter { $0.state == .referenced }.count,
                unverifiableCount: backups.filter { $0.state == .unverifiable }.count
            ),
            notes: scan.notes,
            warnings: scan.warnings
        )
    }

    private var removalNotes: [String] {
        [
            "Only backups that are not referenced by an operation or recovery journal are removed.",
            "Removal is permanent; MacBay does not keep another copy of a removed backup.",
            "Sizes are logical; APFS shared blocks and snapshots can change the actual free space."
        ]
    }

    private func unsafeRemovalReason(for entry: RepairBackupEntry, on volume: URL) -> String? {
        let root = MacBayPaths.backupsRoot(on: volume)
        guard fileSystem.kind(of: root) == .directory else {
            return "The backups root is no longer a readable directory."
        }
        let bundle = URL(fileURLWithPath: entry.path)
        guard isContained(bundle, in: root) else {
            return "The backup is outside the managed backups root."
        }
        let operationDirectory = bundle.deletingLastPathComponent()
        guard fileSystem.kind(of: operationDirectory) == .directory else {
            return "The operation directory is no longer a readable directory."
        }
        guard fileSystem.kind(of: bundle) == .directory else {
            return "The backup bundle is no longer a readable directory."
        }
        return nil
    }

    private func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    private static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isIgnorableMetadata(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store" || name.hasPrefix("._")
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func isOrderedBefore(_ lhs: RepairBackupEntry, _ rhs: RepairBackupEntry) -> Bool {
        switch (lhs.savedAt, rhs.savedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        let nameOrder = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
