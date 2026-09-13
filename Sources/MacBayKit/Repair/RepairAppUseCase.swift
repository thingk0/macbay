import Foundation

public struct RepairAppUseCase: RepairAppUseCaseProtocol, @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (String) -> Void

    private let safetyInspector: any RepairSafetyInspector
    private let bundleOperations: any RepairBundleOperations
    private let manifestRepository: any RepairManifestRepository
    private let journal: any RepairJournaling
    private let volumeInspector: any RepairVolumeInspector
    private let systemRefresher: any SystemEnvironmentRefresher
    private let operationLock: any VolumeOperationLocking

    public init(
        safetyInspector: any RepairSafetyInspector = DarwinRepairSafetyInspector(),
        bundleOperations: any RepairBundleOperations = DarwinRepairBundleOperations(),
        manifestRepository: any RepairManifestRepository = DarwinRepairManifestRepository(),
        journal: any RepairJournaling = DarwinRepairJournal(),
        volumeInspector: any RepairVolumeInspector = DarwinRepairVolumeInspector(),
        systemRefresher: any SystemEnvironmentRefresher = DarwinSystemEnvironmentRefresher(),
        operationLock: any VolumeOperationLocking = VolumeOperationLock()
    ) {
        self.safetyInspector = safetyInspector
        self.bundleOperations = bundleOperations
        self.manifestRepository = manifestRepository
        self.journal = journal
        self.volumeInspector = volumeInspector
        self.systemRefresher = systemRefresher
        self.operationLock = operationLock
    }

    private func normalizeAppName(_ name: String) -> String {
        if name.hasSuffix(".app") {
            return URL(fileURLWithPath: name).lastPathComponent
        }
        return "\(URL(fileURLWithPath: name).lastPathComponent).app"
    }

    public func compare(appName: String, on volume: URL) throws -> RepairComparison {
        let cleanName = normalizeAppName(appName)
        guard let manifestItem = try manifestRepository.findItem(named: cleanName, on: volume) else {
            throw MacBayError.unsupportedOperation(
                "Application '\(cleanName)' is not recorded in manifest on volume \(volume.path)."
            )
        }

        let localURL = URL(fileURLWithPath: manifestItem.sourcePath)
        let externalURL = URL(fileURLWithPath: manifestItem.externalPath)

        guard bundleOperations.fileExists(at: localURL) else {
            throw MacBayError.pathMissing("Local path does not exist: \(localURL.path)")
        }

        guard !bundleOperations.isSymbolicLink(at: localURL) else {
            throw MacBayError.unsupportedOperation(
                "Local application at '\(localURL.path)' is a symbolic link. Repair is only applicable when local duplicate data is detected."
            )
        }

        guard bundleOperations.fileExists(at: externalURL) else {
            throw MacBayError.pathMissing("External recorded copy is missing: \(externalURL.path)")
        }

        let localCopy = try safetyInspector.inspectBundle(at: localURL)
        let externalCopy = try safetyInspector.inspectBundle(at: externalURL)

        var canRedock = true
        var blockers: [String] = []

        if let localId = localCopy.bundleIdentifier, let extId = externalCopy.bundleIdentifier {
            if localId != extId {
                canRedock = false
                blockers.append("Bundle identifier mismatch: local has '\(localId)' but external has '\(extId)'")
            }
        } else if localCopy.bundleIdentifier == nil || externalCopy.bundleIdentifier == nil {
            canRedock = false
            blockers.append("Unable to determine bundle identifier for comparison")
        }

        if localCopy.compatibilityGrade == "Blocked" {
            canRedock = false
            blockers.append("Local application compatibility is Blocked: \(localCopy.compatibilityReasons.joined(separator: ", "))")
        }

        if localCopy.signatureStatus == "Invalid" {
            canRedock = false
            let details = localCopy.signatureDetails ?? "signature corrupted or altered"
            blockers.append("Local application signature verification failed: \(details)")
        }

        let suggestedActions: [RepairAction]
        if canRedock {
            suggestedActions = [.redock, .keepLocal]
        } else {
            suggestedActions = [.keepLocal]
        }

        return RepairComparison(
            appName: cleanName,
            volumePath: volume.path,
            localCopy: localCopy,
            externalCopy: externalCopy,
            canRedock: canRedock,
            redockBlockers: blockers,
            suggestedActions: suggestedActions
        )
    }

    public func plan(
        appName: String,
        action: RepairAction,
        on volume: URL,
        progress: ProgressHandler? = nil
    ) throws -> RepairPlan {
        let cleanName = normalizeAppName(appName)
        let comparison = try compare(appName: cleanName, on: volume)
        let localURL = URL(fileURLWithPath: comparison.localCopy.path)
        let externalURL = URL(fileURLWithPath: comparison.externalCopy.path)

        switch action {
        case .keepLocal:
            return RepairPlan(
                action: .keepLocal,
                appName: cleanName,
                localURL: localURL,
                externalURL: externalURL,
                backupURL: nil,
                stagingURL: nil,
                volumeURL: volume,
                status: .ready,
                sizeBytes: comparison.localCopy.sizeBytes,
                requiredExternalSpaceBytes: 0,
                estimatedFreedInternalBytes: 0,
                warnings: ["External copy will remain as an unmanaged archive at: \(externalURL.path)"]
            )

        case .redock:
            guard comparison.canRedock else {
                throw MacBayError.unsupportedOperation(
                    "Cannot redock '\(cleanName)': \(comparison.redockBlockers.joined(separator: "; "))"
                )
            }

            try safetyInspector.assertSafeToOperate(at: [localURL, externalURL])

            guard volumeInspector.isWritable(volume: volume) else {
                throw MacBayError.invalidVolume("Volume at \(volume.path) is read-only.")
            }

            let localSize = try bundleOperations.calculateSizeBytes(at: localURL)
            let avail = try volumeInspector.availableBytes(on: volume)
            if avail < localSize {
                throw MacBayError.insufficientSpace(
                    path: volume.path,
                    neededBytes: localSize,
                    availableBytes: avail
                )
            }

            let opId = UUID().uuidString
            let backupURL = MacBayPaths.backupsRoot(on: volume)
                .appendingPathComponent(opId, isDirectory: true)
                .appendingPathComponent(cleanName)
            let stagingURL = MacBayPaths.operationsRoot(on: volume)
                .appendingPathComponent(".staging-\(opId)", isDirectory: true)
                .appendingPathComponent(cleanName)

            let status: RepairPlanStatus
            if comparison.localCopy.compatibilityGrade == "PopupRisk" {
                status = .reviewRequired(
                    reasons: comparison.localCopy.compatibilityReasons,
                    evidence: ["Application declares privileged helper tools or launch services"]
                )
            } else {
                status = .ready
            }

            return RepairPlan(
                action: .redock,
                appName: cleanName,
                localURL: localURL,
                externalURL: externalURL,
                backupURL: backupURL,
                stagingURL: stagingURL,
                volumeURL: volume,
                status: status,
                sizeBytes: localSize,
                requiredExternalSpaceBytes: localSize,
                estimatedFreedInternalBytes: localSize,
                warnings: ["Existing external copy will be moved to backup: \(backupURL.path)"]
            )
        }
    }

    public func execute(
        plan: RepairPlan,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> RepairExecutionResult {
        if case let .reviewRequired(reasons, _) = plan.status, !force {
            throw MacBayError.forceRequired(
                path: plan.localURL.path,
                assessment: CompatibilityAssessment(
                    grade: .popupRisk,
                    reasons: reasons,
                    evidence: ["Popup risk detected during repair preflight"]
                )
            )
        }

        if case let .blocked(reason, _) = plan.status {
            throw MacBayError.unsupportedOperation(reason)
        }

        if journal.load(appName: plan.appName, on: plan.volumeURL) != nil {
            throw MacBayError.operationInProgress(
                path: plan.volumeURL.path,
                details: "An incomplete repair for '\(plan.appName)' is pending. Run 'mb repair \"\(plan.appName)\" --rollback' first."
            )
        }

        try safetyInspector.assertSafeToOperate(at: [plan.localURL, plan.externalURL])
        guard volumeInspector.isWritable(volume: plan.volumeURL) else {
            throw MacBayError.invalidVolume("Volume at \(plan.volumeURL.path) is read-only.")
        }
        guard bundleOperations.fileExists(at: plan.localURL) else {
            throw MacBayError.pathMissing(plan.localURL.path)
        }
        guard bundleOperations.fileExists(at: plan.externalURL) else {
            throw MacBayError.pathMissing(plan.externalURL.path)
        }

        return try operationLock.withVolumeLock(on: plan.volumeURL) {
            switch plan.action {
            case .keepLocal:
                progress?("Removing migration record from manifest")
                try manifestRepository.removeItem(named: plan.appName, on: plan.volumeURL)
                return RepairExecutionResult(
                    action: .keepLocal,
                    appName: plan.appName,
                    outcome: .completed,
                    localPath: plan.localURL.path,
                    externalPath: plan.externalURL.path,
                    backupPath: nil,
                    symlinkPath: nil,
                    freedBytes: 0
                )

            case .redock:
                let opId = UUID().uuidString
                let backupURL = plan.backupURL ?? MacBayPaths.backupsRoot(on: plan.volumeURL)
                    .appendingPathComponent(opId, isDirectory: true)
                    .appendingPathComponent(plan.appName)
                let stagingURL = plan.stagingURL ?? MacBayPaths.operationsRoot(on: plan.volumeURL)
                    .appendingPathComponent(".staging-\(opId)", isDirectory: true)
                    .appendingPathComponent(plan.appName)
                let localBackupURL = plan.localURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(plan.appName).macbay-local-backup-\(opId)")

                guard let originalItem = try manifestRepository.findItem(named: plan.appName, on: plan.volumeURL) else {
                    throw MacBayError.pathMissing("Manifest item for \(plan.appName)")
                }

                var record = RepairJournalRecord(
                    id: opId,
                    appName: plan.appName,
                    localPath: plan.localURL.path,
                    externalPath: plan.externalURL.path,
                    backupPath: backupURL.path,
                    stagingPath: stagingURL.path,
                    localBackupPath: localBackupURL.path,
                    volumePath: plan.volumeURL.path,
                    phase: .started,
                    timestamp: macBayTimestamp(),
                    originalManifestItem: originalItem
                )
                try journal.save(record, on: plan.volumeURL)

                // Stage 1: Copy to staging
                progress?("Staging local bundle on external volume")
                do {
                    try bundleOperations.copyBundle(from: plan.localURL, to: stagingURL)
                    let stagedCopy = try safetyInspector.inspectBundle(at: stagingURL)
                    if stagedCopy.signatureStatus == "Invalid" {
                        throw MacBayError.signatureVerificationFailed(
                            path: stagingURL.path,
                            details: stagedCopy.signatureDetails ?? "staged bundle signature corrupt"
                        )
                    }
                    record = record.updatingPhase(.staged)
                    try journal.save(record, on: plan.volumeURL)
                } catch {
                    try? bundleOperations.remove(at: stagingURL)
                    journal.remove(appName: plan.appName, on: plan.volumeURL)
                    throw error
                }

                // Stage 2: Move existing external copy to backup
                progress?("Moving existing external copy to backup directory")
                do {
                    try bundleOperations.moveBundle(from: plan.externalURL, to: backupURL)
                    record = record.updatingPhase(.backedUpExternal)
                    try journal.save(record, on: plan.volumeURL)
                } catch {
                    try? bundleOperations.remove(at: stagingURL)
                    journal.remove(appName: plan.appName, on: plan.volumeURL)
                    throw error
                }

                // Stage 3: Move staging to destination
                progress?("Placing new bundle at external destination")
                do {
                    try bundleOperations.moveBundle(from: stagingURL, to: plan.externalURL)
                    record = record.updatingPhase(.placedNewExternal)
                    try journal.save(record, on: plan.volumeURL)
                } catch {
                    // Rollback Stage 2: restore backup to external
                    try? bundleOperations.moveBundle(from: backupURL, to: plan.externalURL)
                    try? bundleOperations.remove(at: stagingURL)
                    journal.remove(appName: plan.appName, on: plan.volumeURL)
                    throw error
                }

                // Stage 4: Swap local app with symlink
                progress?("Updating local application symlink")
                do {
                    try bundleOperations.moveBundle(from: plan.localURL, to: localBackupURL)
                    try bundleOperations.createSymlink(at: plan.localURL, pointingTo: plan.externalURL)
                    record = record.updatingPhase(.linked)
                    try journal.save(record, on: plan.volumeURL)
                } catch {
                    // Rollback Stage 4: remove symlink, restore local app
                    try? bundleOperations.remove(at: plan.localURL)
                    if bundleOperations.fileExists(at: localBackupURL) {
                        try? bundleOperations.moveBundle(from: localBackupURL, to: plan.localURL)
                    }
                    // Rollback Stage 3 & 2: restore backup to external
                    try? bundleOperations.remove(at: plan.externalURL)
                    try? bundleOperations.moveBundle(from: backupURL, to: plan.externalURL)
                    journal.remove(appName: plan.appName, on: plan.volumeURL)
                    throw error
                }

                // Stage 5: Update manifest
                progress?("Updating manifest record")
                let newItem = DockedItem(
                    name: originalItem.name,
                    sourcePath: plan.localURL.path,
                    externalPath: plan.externalURL.path,
                    sizeBytes: plan.sizeBytes,
                    kind: originalItem.kind,
                    dockedAt: macBayTimestamp()
                )
                do {
                    try manifestRepository.recordItem(newItem, on: plan.volumeURL)
                    record = record.updatingPhase(.manifestUpdated)
                    try journal.save(record, on: plan.volumeURL)
                } catch {
                    // Rollback Stage 5: restore original manifest
                    try? manifestRepository.recordItem(originalItem, on: plan.volumeURL)
                    // Rollback Stage 4: remove symlink, restore local app
                    try? bundleOperations.remove(at: plan.localURL)
                    if bundleOperations.fileExists(at: localBackupURL) {
                        try? bundleOperations.moveBundle(from: localBackupURL, to: plan.localURL)
                    }
                    // Rollback Stage 3 & 2: restore backup to external
                    try? bundleOperations.remove(at: plan.externalURL)
                    try? bundleOperations.moveBundle(from: backupURL, to: plan.externalURL)
                    journal.remove(appName: plan.appName, on: plan.volumeURL)
                    throw error
                }

                // Stage 6: Finalize
                progress?("Cleaning up temporary local backup and journal")
                try? bundleOperations.remove(at: localBackupURL)
                try? bundleOperations.remove(at: stagingURL.deletingLastPathComponent())
                journal.remove(appName: plan.appName, on: plan.volumeURL)
                systemRefresher.refreshLaunchServices(for: plan.localURL)

                return RepairExecutionResult(
                    action: .redock,
                    appName: plan.appName,
                    outcome: .completed,
                    localPath: plan.localURL.path,
                    externalPath: plan.externalURL.path,
                    backupPath: backupURL.path,
                    symlinkPath: "\(plan.localURL.path) -> \(plan.externalURL.path)",
                    freedBytes: plan.sizeBytes
                )
            }
        }
    }

    public func rollback(
        appName: String,
        on volume: URL,
        progress: ProgressHandler? = nil
    ) throws -> RepairExecutionResult {
        return try operationLock.withVolumeLock(on: volume) {
            let cleanName = normalizeAppName(appName)
            guard let record = journal.load(appName: cleanName, on: volume) else {
                throw MacBayError.unsupportedOperation(
                    "No pending repair operation found for '\(cleanName)' on \(volume.path)."
                )
            }

            let localURL = URL(fileURLWithPath: record.localPath)
            let externalURL = URL(fileURLWithPath: record.externalPath)
            let backupURL = URL(fileURLWithPath: record.backupPath)
            let stagingURL = URL(fileURLWithPath: record.stagingPath)
            let localBackupURL = URL(fileURLWithPath: record.localBackupPath)

            progress?("Rolling back phase: \(record.phase.rawValue)")

            var rollbackErrors: [String] = []

            // If manifest was updated, restore original item
            if record.phase == .manifestUpdated {
                do {
                    try manifestRepository.recordItem(record.originalManifestItem, on: volume)
                } catch {
                    rollbackErrors.append("Failed to restore original manifest: \(error.localizedDescription)")
                }
            }

            // If symlink was linked, restore local app
            if record.phase == .linked || record.phase == .manifestUpdated {
                if bundleOperations.isSymbolicLink(at: localURL) {
                    try? bundleOperations.remove(at: localURL)
                }
                if bundleOperations.fileExists(at: localBackupURL) {
                    do {
                        try bundleOperations.moveBundle(from: localBackupURL, to: localURL)
                    } catch {
                        rollbackErrors.append("Failed to restore local app from \(localBackupURL.path): \(error.localizedDescription)")
                    }
                }
            }

            // If new bundle was placed at externalURL, remove it
            if record.phase == .placedNewExternal || record.phase == .linked || record.phase == .manifestUpdated {
                if bundleOperations.fileExists(at: externalURL) && bundleOperations.fileExists(at: backupURL) {
                    try? bundleOperations.remove(at: externalURL)
                }
            }

            // If external was backed up, restore it to externalURL
            if record.phase == .backedUpExternal || record.phase == .placedNewExternal || record.phase == .linked || record.phase == .manifestUpdated {
                if bundleOperations.fileExists(at: backupURL) && !bundleOperations.fileExists(at: externalURL) {
                    do {
                        try bundleOperations.moveBundle(from: backupURL, to: externalURL)
                    } catch {
                        rollbackErrors.append("Failed to restore external backup to \(externalURL.path): \(error.localizedDescription)")
                    }
                }
            }

            // Clean up staging
            try? bundleOperations.remove(at: stagingURL)
            try? bundleOperations.remove(at: stagingURL.deletingLastPathComponent())

            if !rollbackErrors.isEmpty {
                throw MacBayError.unsupportedOperation(
                    "Rollback incomplete for '\(cleanName)': \(rollbackErrors.joined(separator: "; "))"
                )
            }

            journal.remove(appName: cleanName, on: volume)
            systemRefresher.refreshLaunchServices(for: localURL)

            return RepairExecutionResult(
                action: .redock,
                appName: cleanName,
                outcome: .noChanges(reason: "Rollback completed: original local and external copies and manifest restored."),
                localPath: localURL.path,
                externalPath: externalURL.path,
                backupPath: backupURL.path,
                symlinkPath: nil,
                freedBytes: 0
            )
        }
    }
}
