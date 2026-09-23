import Foundation

public struct MacBayService {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let manifestStore: ManifestStore
    private let updateWorkflowStore: UpdateWorkflowStore
    private let localAppRecoveryManager: LocalAppRecoveryManager
    private let scanner: AppScanner
    private let bundleMigrator: BundleMigrator
    private let appAdopter: AppAdopter
    public let adoptAppUseCase: any AdoptAppUseCaseProtocol
    public let repairAppUseCase: any RepairAppUseCaseProtocol
    private let xcodeDoctor: XcodeDoctor
    private let cacheManager: CacheManager
    private let purgeEngine: PurgeEngine
    private let directoryMover: DirectoryMoveManager
    private let teardownManager: TeardownManager
    private let historyStore: HistoryStore
    private let explorerScanner: ExplorerScanner
    private let scanRecordStore: ScanRecordStore
    private let explorerRefresher: ExplorerRefresher
    private let applicationsDirectory: URL

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil,
        updateWorkflowStore: UpdateWorkflowStore? = nil,
        adoptAppUseCase: (any AdoptAppUseCaseProtocol)? = nil,
        repairAppUseCase: (any RepairAppUseCaseProtocol)? = nil,
        historyStore: HistoryStore? = nil,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
        self.historyStore = historyStore ?? HistoryStore(fileManager: fileManager)
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.manifestStore = ManifestStore(fileManager: fileManager)
        self.updateWorkflowStore = updateWorkflowStore ?? UpdateWorkflowStore(fileManager: fileManager)
        self.localAppRecoveryManager = LocalAppRecoveryManager(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager,
            applicationsDirectory: self.applicationsDirectory
        )
        self.scanner = AppScanner(
            fileManager: fileManager,
            commandRunner: commandRunner,
            diskInfoProvider: self.volumeManager.diskInfoProvider,
            manifestStore: self.manifestStore
        )
        self.bundleMigrator = BundleMigrator(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager
        )
        self.appAdopter = AppAdopter(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager,
            manifestStore: self.manifestStore
        )
        self.adoptAppUseCase = adoptAppUseCase ?? AdoptAppUseCase(
            safetyInspector: DarwinAppSafetyInspector(fileManager: fileManager, commandRunner: commandRunner),
            fileOperations: DarwinBundleFileOperations(fileManager: fileManager),
            manifestRepository: DarwinManifestRepository(fileManager: fileManager),
            operationJournal: DarwinOperationJournal(fileManager: fileManager),
            systemRefresher: DarwinSystemEnvironmentRefresher(fileManager: fileManager, commandRunner: commandRunner),
            volumeInspector: DarwinVolumeStorageInspector(volumeManager: self.volumeManager)
        )
        self.repairAppUseCase = repairAppUseCase ?? RepairAppUseCase(
            safetyInspector: DarwinRepairSafetyInspector(fileManager: fileManager, commandRunner: commandRunner),
            bundleOperations: DarwinRepairBundleOperations(fileManager: fileManager, commandRunner: commandRunner),
            manifestRepository: DarwinRepairManifestRepository(fileManager: fileManager),
            journal: DarwinRepairJournal(fileManager: fileManager),
            volumeInspector: DarwinRepairVolumeInspector(fileManager: fileManager),
            systemRefresher: DarwinSystemEnvironmentRefresher(fileManager: fileManager, commandRunner: commandRunner)
        )
        self.xcodeDoctor = XcodeDoctor(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager
        )
        self.cacheManager = CacheManager(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
        self.purgeEngine = PurgeEngine(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
        self.directoryMover = DirectoryMoveManager(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager
        )
        self.explorerScanner = ExplorerScanner(
            fileManager: fileManager,
            diskInfoProvider: self.volumeManager.diskInfoProvider
        )
        self.scanRecordStore = ScanRecordStore(
            fileManager: fileManager
        )
        self.explorerRefresher = ExplorerRefresher(
            fileManager: fileManager,
            diskInfoProvider: self.volumeManager.diskInfoProvider,
            recordStore: self.scanRecordStore
        )
        self.teardownManager = TeardownManager(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager,
            configStore: self.configStore,
            cacheManager: self.cacheManager
        )
    }

    public func status(volumePath: String? = nil) throws -> StatusReport {
        let (eligibleVolumes, initialWarnings) = try volumeManager.externalVolumesWithWarnings()
        var externalVolumes = eligibleVolumes
        var warnings = initialWarnings

        if let volumePath {
            let selected = try volumeManager.resolveExternalVolume(path: volumePath)
            if !externalVolumes.contains(where: { $0.path == selected.path }) {
                externalVolumes.append(selected)
                externalVolumes.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            }
        }

        var dockedItems: [DockedItem] = []
        for volume in externalVolumes {
            do {
                dockedItems.append(contentsOf: try manifestStore.load(on: URL(fileURLWithPath: volume.path)).items)
            } catch {
                warnings.append("Unable to load manifest for \(volume.path): \(error.localizedDescription)")
            }
        }

        return StatusReport(
            generatedAt: macBayTimestamp(),
            internalVolume: try volumeManager.internalVolume(),
            externalVolumes: externalVolumes,
            defaultVolume: statusDefaultVolume(warnings: &warnings),
            dockedItems: dockedItems.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            warnings: warnings
        )
    }

    private func statusDefaultVolume(warnings: inout [String]) -> StatusDefaultVolume? {
        let configured: DefaultVolume?
        do {
            configured = try configStore.load().defaultVolume
        } catch {
            warnings.append(
                "Unable to read MacBay configuration at \(configStore.configURL.path): \(error.localizedDescription)"
            )
            configured = nil
        }
        guard let configured else { return nil }

        switch volumeManager.availability(of: configured) {
        case let .mounted(volume, pathChanged):
            if pathChanged {
                warnings.append(
                    "Default volume '\(configured.name)' is mounted at \(volume.path) instead of the saved path \(configured.path)."
                )
            }
            return StatusDefaultVolume(
                name: configured.name,
                path: configured.path,
                uuid: configured.uuid,
                mountedPath: volume.path
            )
        case .notMounted:
            warnings.append(
                "Default volume '\(configured.name)' (\(configured.path)) is not mounted. Connect it, pass --volume, or run 'mb init'."
            )
            return StatusDefaultVolume(name: configured.name, path: configured.path, uuid: configured.uuid)
        case let .ineligible(mountPoint, reason):
            warnings.append(
                "Default volume '\(configured.name)' (\(mountPoint)) is not eligible: \(reason). Run 'mb init' to choose another volume."
            )
            return StatusDefaultVolume(
                name: configured.name,
                path: configured.path,
                uuid: configured.uuid,
                mountedPath: mountPoint
            )
        }
    }

    public func scan(
        minimumApplicationSizeBytes: UInt64 = AppScanner.defaultMinimumApplicationSizeBytes,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications")],
        developerCacheTargets: [DeveloperCacheTarget] = AppScanner.defaultDeveloperCacheTargets()
    ) -> ScanReport {
        scanner.scan(
            minimumApplicationSizeBytes: minimumApplicationSizeBytes,
            applicationDirectories: applicationDirectories,
            developerCacheTargets: developerCacheTargets
        )
    }

    public func doctor(
        volumePath: String? = nil,
        fix: Bool = false,
        dryRun: Bool = false
    ) throws -> DoctorReport {
        let checker = DoctorChecker(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: volumeManager,
            manifestStore: manifestStore,
            configStore: configStore
        )
        return try checker.check(volumePath: volumePath, fix: fix, dryRun: dryRun)
    }

    public func explore(
        path: String,
        recordScan: Bool = true
    ) throws -> ExplorerScanReport {
        let root = MacBayPaths.expandedURL(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MacBayError.pathMissing(root.path)
        }
        let scan = explorerScanner.scanDirectory(root)
        let previous = scanRecordStore.load(forRootPath: scan.rootPath)
        let report = scanRecordStore.buildReport(from: scan, previous: previous)
        if recordScan {
            try? scanRecordStore.save(report)
        }
        return report
    }

    public func explorePreview(path: String, dryRun: Bool = true) -> ExplorerScanReport? {
        guard let report = try? explore(path: path, recordScan: false) else { return nil }
        _ = dryRun
        return report
    }

    public func exploreMovePreview(path: String, volumePath: String?) throws -> MigrationResult {
        if let volumePath {
            let selected = try volumeManager.resolveExternalVolume(path: volumePath)
            return try directoryMover.move(
                path: path,
                on: URL(fileURLWithPath: selected.path),
                dryRun: true
            )
        }
        let selection = try selectVolume(path: nil)
        return try directoryMover.move(
            path: path,
            on: URL(fileURLWithPath: selection.volume.path),
            dryRun: true
        )
    }

    public func refreshExplorer(
        root: String,
        changedPaths: [String],
        droppedEvents: Bool = false,
        recordScan: Bool = true
    ) -> ExplorerRefreshResult? {
        explorerRefresher.refresh(
            root: root,
            event: ExplorerChangeEvent(changedPaths: changedPaths, droppedEvents: droppedEvents),
            recordScan: recordScan
        )
    }

    public func history(limit: Int? = nil, command: String? = nil) -> [HistoryEntry] {
        historyStore.entries(limit: limit, command: command)
    }

    /// The newest history entry `mb undo` may reverse, or an error explaining why none can be.
    public func planUndo() throws -> UndoPlan {
        try UndoPlanner.plan(from: historyStore.entries())
    }

    /// Reverses `plan` with the matching restore. A dry run checks that the current
    /// state still matches the entry (for example, that the app is still docked)
    /// without changing anything; only real runs are recorded.
    public func undo(
        _ plan: UndoPlan,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> UndoReport {
        let subject = "\(plan.entry.command) \(plan.entry.subject)"
        do {
            let result: MigrationResult
            switch plan.operation {
            case .undock:
                // undock records its own history entry.
                result = try undock(appName: plan.target, volumePath: volumePath, dryRun: dryRun, progress: progress)
            case .unmove:
                result = try unmove(path: plan.target, volumePath: volumePath, dryRun: dryRun, progress: progress)
                recordOperation(
                    command: "unmove", subject: result.destinationPath, outcome: .success,
                    undo: "mb move \(ShellEnvironmentWriter.shellQuoted(result.destinationPath))", dryRun: dryRun
                )
            }
            recordOperation(
                command: "undo", subject: subject, outcome: .success,
                detail: "ran \(plan.command)", dryRun: dryRun
            )
            return UndoReport(entry: plan.entry, command: plan.command, result: result, dryRun: dryRun)
        } catch {
            recordOperation(
                command: "undo", subject: subject, outcome: .failure,
                detail: error.localizedDescription, dryRun: dryRun
            )
            throw error
        }
    }

    public func references(paths: [String]) throws -> ReferenceReport {
        let checker = ExternalReferenceChecker(fileManager: fileManager)
        let result = checker.check(paths: paths)
        return ReferenceReport(
            generatedAt: macBayTimestamp(),
            findings: result.findings,
            notes: result.notes
        )
    }

    /// Records one entry in the shared operation history for a mutating call.
    /// Recording happens here (not only in the CLI layer) so TUI-triggered
    /// operations are logged too.
    private func recordOperation(
        command: String,
        subject: String,
        outcome: HistoryOutcome,
        detail: String? = nil,
        undo: String? = nil,
        dryRun: Bool = false
    ) {
        guard !dryRun else { return }
        historyStore.record(HistoryEntry(
            command: command,
            subject: subject,
            outcome: outcome,
            detail: detail,
            undo: undo
        ))
    }

    /// The history subject for an app argument. A path argument is recorded as the
    /// absolute path it resolves to, so the undo hint and `mb undo` work from any
    /// directory; a plain name such as `Xcode.app` is kept as typed.
    private func historySubject(forApp appName: String) -> String {
        appName.contains("/") ? MacBayPaths.applicationURL(named: appName).path : appName
    }

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        let subject = historySubject(forApp: appName)
        do {
            progress?(.selectingVolume)
            let selection = try selectVolume(path: volumePath)
            let result = try bundleMigrator.dock(
                appName: appName,
                on: URL(fileURLWithPath: selection.volume.path),
                dryRun: dryRun,
                force: force,
                progress: progress
            )
            recordOperation(
                command: "dock", subject: subject, outcome: .success,
                undo: "mb undock \(ShellEnvironmentWriter.shellQuoted(subject))", dryRun: dryRun
            )
            return result
        } catch {
            recordOperation(
                command: "dock", subject: subject, outcome: .failure,
                detail: error.localizedDescription, dryRun: dryRun
            )
            throw error
        }
    }

    public func planAdopt(
        appName: String,
        volumePath: String?,
        progress: ProgressHandler? = nil
    ) throws -> AdoptPlan {
        progress?(.selectingVolume)
        let selection = try selectVolume(path: volumePath)
        return try adoptAppUseCase.plan(
            appName: appName,
            on: URL(fileURLWithPath: selection.volume.path),
            progress: progress
        )
    }

    public func executeAdopt(
        plan: AdoptPlan,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> AdoptExecutionResult {
        do {
            let result = try adoptAppUseCase.execute(plan: plan, force: force, progress: progress)
            recordOperation(command: "adopt", subject: plan.appName, outcome: .success)
            return result
        } catch {
            recordOperation(
                command: "adopt", subject: plan.appName, outcome: .failure,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    public func adopt(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        let plan = try planAdopt(appName: appName, volumePath: volumePath, progress: progress)
        if dryRun {
            return MigrationResult(
                operation: "adopt",
                name: plan.appName,
                sourcePath: plan.targetURL.path,
                destinationPath: plan.destinationURL.path,
                sizeBytes: plan.sizeBytes,
                dryRun: true,
                messages: [
                    "Action: \(plan.mode == .alreadyAdopted ? "Already adopted in MacBay (no changes needed)" : "Adopt application into MacBay standard storage")",
                    "Symlink: \(plan.symlinkURL.path) -> \(plan.destinationURL.path)",
                    "Space: estimated internal space freed 0 B (same-volume relocation)",
                    "Dry run: no files were changed"
                ],
                compatibility: plan.compatibility
            )
        }
        let result = try executeAdopt(plan: plan, force: force, progress: progress)
        return MigrationResult(
            operation: "adopt",
            name: result.appName,
            sourcePath: result.sourcePath,
            destinationPath: result.destinationPath,
            sizeBytes: result.sizeBytes,
            dryRun: false,
            messages: [
                "Symlink: \(result.symlinkPath) -> \(result.destinationPath)",
                "Recorded in manifest on \(plan.volumeURL.path)"
            ],
            compatibility: plan.compatibility
        )
    }

    public func compareApp(appName: String, volumePath: String?) throws -> RepairComparison {
        let selection = try selectVolume(path: volumePath)
        return try repairAppUseCase.compare(
            appName: appName,
            on: URL(fileURLWithPath: selection.volume.path)
        )
    }

    public func planRepair(
        appName: String,
        action: RepairAction,
        volumePath: String?,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> RepairPlan {
        let selection = try selectVolume(path: volumePath)
        return try repairAppUseCase.plan(
            appName: appName,
            action: action,
            on: URL(fileURLWithPath: selection.volume.path),
            progress: progress
        )
    }

    public func executeRepair(
        plan: RepairPlan,
        force: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> RepairExecutionResult {
        do {
            let result = try repairAppUseCase.execute(plan: plan, force: force, progress: progress)
            recordOperation(
                command: "repair \(plan.action.rawValue)", subject: plan.appName, outcome: .success
            )
            return result
        } catch {
            recordOperation(
                command: "repair \(plan.action.rawValue)", subject: plan.appName, outcome: .failure,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    public func rollbackRepair(
        appName: String,
        volumePath: String?,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> RepairExecutionResult {
        do {
            let selection = try selectVolume(path: volumePath)
            let result = try repairAppUseCase.rollback(
                appName: appName,
                on: URL(fileURLWithPath: selection.volume.path),
                progress: progress
            )
            recordOperation(command: "repair --rollback", subject: appName, outcome: .success)
            return result
        } catch {
            recordOperation(
                command: "repair --rollback", subject: appName, outcome: .failure,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    public func undock(appName: String, volumePath: String?, dryRun: Bool, progress: ProgressHandler? = nil) throws -> MigrationResult {
        let subject = historySubject(forApp: appName)
        do {
            progress?(.selectingVolume)
            let volume: URL?
            let fallbackVolume: URL?
            if let volumePath {
                let selected = try volumeManager.resolveExternalVolume(path: volumePath)
                volume = URL(fileURLWithPath: selected.path)
                fallbackVolume = nil
            } else {
                volume = nil
                fallbackVolume = mountedConfiguredVolume().map { URL(fileURLWithPath: $0.path) }
            }
            let result = try bundleMigrator.undock(
                appName: appName,
                from: volume,
                fallbackVolume: fallbackVolume,
                dryRun: dryRun,
                progress: progress
            )
            recordOperation(
                command: "undock", subject: subject, outcome: .success,
                undo: "mb dock \(ShellEnvironmentWriter.shellQuoted(subject))", dryRun: dryRun
            )
            return result
        } catch {
            recordOperation(
                command: "undock", subject: subject, outcome: .failure,
                detail: error.localizedDescription, dryRun: dryRun
            )
            throw error
        }
    }

    /// Restores a MacBay-managed application to /Applications before its vendor
    /// updater runs. The original external volume and bundle identity are kept in
    /// local state so a later finish can safely return the app to that volume.
    public func beginAppUpdate(
        appName: String,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> UpdateWorkflowReport {
        let source = MacBayPaths.applicationURL(named: appName)
        guard source.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(source.path)
        }

        let existing = try updateWorkflowStore.record(for: source.lastPathComponent)
        if let existing, existing.phase == .awaitingUpdate {
            throw MacBayError.unsupportedOperation(
                "An update is already awaiting completion for \(existing.appName). Run 'mb update finish \(existing.appName)'."
            )
        }

        let targetURL: URL
        do {
            let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            targetURL = URL(
                fileURLWithPath: rawTarget,
                relativeTo: source.deletingLastPathComponent()
            ).standardizedFileURL
        } catch {
            if let existing, fileManager.fileExists(atPath: existing.sourcePath) {
                var recovered = existing
                recovered.phase = .awaitingUpdate
                if !dryRun {
                    try updateWorkflowStore.update(recovered)
                }
                let metadata = try appBundleMetadata(at: URL(fileURLWithPath: recovered.sourcePath))
                return UpdateWorkflowReport(
                    operation: "begin",
                    record: recovered,
                    currentVersion: metadata.version,
                    currentBuild: metadata.build,
                    dryRun: dryRun,
                    messages: [
                        "The app was already restored before the previous command stopped.",
                        "Complete the vendor update, then run 'mb update finish \(recovered.appName)'."
                    ]
                )
            }
            throw MacBayError.unsupportedOperation(
                "Application is not a MacBay-managed external link: \(source.path)"
            )
        }

        let volumePath = try macBayVolumePath(for: targetURL, appName: source.lastPathComponent)
        let selection = try volumeManager.resolveExternalVolume(path: volumePath)
        let volumeURL = URL(fileURLWithPath: selection.path)
        let volumeInfo = try volumeManager.diskInfoProvider.diskInfo(for: selection.path)
        guard let volumeUUID = volumeInfo.volumeUUID, !volumeUUID.isEmpty else {
            throw MacBayError.invalidVolume(
                "Unable to record the original volume UUID for \(selection.path); update workflow stopped safely."
            )
        }

        let manifest = try manifestStore.load(on: volumeURL)
        guard manifest.items.contains(where: {
            $0.kind == .application &&
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == source.path &&
            URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path == targetURL.path
        }) else {
            throw MacBayError.manifestFailed(
                path: MacBayPaths.manifestURL(on: volumeURL).path,
                details: "The external app link and MacBay manifest do not match."
            )
        }

        let metadata = try appBundleMetadata(at: targetURL)
        guard let bundleIdentifier = metadata.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw MacBayError.invalidApplication(
                "Application bundle has no CFBundleIdentifier: \(targetURL.path)"
            )
        }

        let record = existing ?? UpdateWorkflowRecord(
            appName: source.lastPathComponent,
            sourcePath: source.path,
            externalPath: targetURL.path,
            bundleIdentifier: bundleIdentifier,
            originalVersion: metadata.version,
            originalBuild: metadata.build,
            volumePath: selection.path,
            volumeName: volumeInfo.volumeName,
            volumeUUID: volumeUUID
        )

        guard record.bundleIdentifier == bundleIdentifier,
              record.externalPath == targetURL.path,
              record.volumeUUID.caseInsensitiveCompare(volumeUUID) == .orderedSame else {
            throw MacBayError.unsupportedOperation(
                "The recorded update target no longer matches the external app. Inspect 'mb update status' before continuing."
            )
        }

        let preview = try undock(
            appName: source.path,
            volumePath: selection.path,
            dryRun: true,
            progress: progress
        )
        if dryRun {
            return UpdateWorkflowReport(
                operation: "begin",
                record: record,
                currentVersion: metadata.version,
                currentBuild: metadata.build,
                migration: preview,
                dryRun: true,
                messages: [
                    "After restoring the app, run its vendor updater, then 'mb update finish \(record.appName)'."
                ]
            )
        }

        if existing == nil {
            try updateWorkflowStore.insert(record)
        }

        do {
            let migration = try undock(
                appName: source.path,
                volumePath: selection.path,
                dryRun: false,
                progress: progress
            )
            var awaiting = record
            awaiting.phase = .awaitingUpdate
            try updateWorkflowStore.update(awaiting)
            return UpdateWorkflowReport(
                operation: "begin",
                record: awaiting,
                currentVersion: metadata.version,
                currentBuild: metadata.build,
                migration: migration,
                dryRun: false,
                messages: [
                    "Run the app's vendor updater while it is in /Applications.",
                    "When the update is complete, run 'mb update finish \(record.appName)'."
                ]
            )
        } catch {
            if !isSymbolicLink(at: source), fileManager.fileExists(atPath: source.path) {
                var awaiting = record
                awaiting.phase = .awaitingUpdate
                try? updateWorkflowStore.update(awaiting)
            } else if existing == nil {
                try? updateWorkflowStore.remove(appName: record.appName)
            }
            throw error
        }
    }

    /// Re-externalizes a locally updated app to the same physical volume recorded
    /// by begin. Any validation or copy failure leaves the app local and the
    /// workflow record available for a later retry.
    public func finishAppUpdate(
        appName: String,
        force: Bool = false,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> UpdateWorkflowReport {
        guard let record = try updateWorkflowStore.record(for: appName) else {
            throw MacBayError.unsupportedOperation(
                "No update workflow is recorded for \(appName). Run 'mb update begin \(appName)' first."
            )
        }

        let source = URL(fileURLWithPath: record.sourcePath).standardizedFileURL
        let volume = try updateWorkflowVolume(for: record)
        let expectedExternal = MacBayPaths.applicationsRoot(on: URL(fileURLWithPath: volume.path))
            .appendingPathComponent(record.appName, isDirectory: true)
            .standardizedFileURL

        if let currentTarget = symlinkDestination(at: source) {
            let manifestMatches = try manifestStore.load(on: URL(fileURLWithPath: volume.path)).items.contains {
                $0.kind == .application &&
                URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == source.path &&
                URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path == currentTarget.path
            }
            guard currentTarget.path == expectedExternal.path, manifestMatches else {
                throw MacBayError.unsupportedOperation(
                    "The app path is already a symlink, but it does not match the recorded MacBay destination."
                )
            }
            let metadata = try appBundleMetadata(at: currentTarget)
            guard metadata.bundleIdentifier == record.bundleIdentifier else {
                throw MacBayError.unsupportedOperation(
                    "Bundle identifier changed from \(record.bundleIdentifier) to \(metadata.bundleIdentifier ?? "missing"). The update record is preserved."
                )
            }
            if !dryRun {
                try updateWorkflowStore.remove(appName: record.appName)
            }
            return UpdateWorkflowReport(
                operation: "finish",
                record: record,
                currentVersion: metadata.version,
                currentBuild: metadata.build,
                dryRun: dryRun,
                messages: [
                    dryRun
                        ? "The app is already re-externalized; this preview will only clear the completed workflow record."
                        : "The app was already re-externalized; the completed workflow record was cleared."
                ]
            )
        }

        guard fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.pathMissing(source.path)
        }
        let metadata = try appBundleMetadata(at: source)
        guard metadata.bundleIdentifier == record.bundleIdentifier else {
            throw MacBayError.unsupportedOperation(
                "Bundle identifier changed from \(record.bundleIdentifier) to \(metadata.bundleIdentifier ?? "missing"). The app remains in /Applications and the update record is preserved."
            )
        }

        let preview = try dock(
            appName: source.path,
            volumePath: volume.path,
            dryRun: true,
            force: force,
            progress: progress
        )
        if dryRun {
            return UpdateWorkflowReport(
                operation: "finish",
                record: record,
                currentVersion: metadata.version,
                currentBuild: metadata.build,
                migration: preview,
                dryRun: true,
                messages: ["The app will be returned to its original MacBay volume."]
            )
        }

        _ = try dock(
            appName: source.path,
            volumePath: volume.path,
            dryRun: false,
            force: force,
            progress: progress
        )

        guard let finalTarget = symlinkDestination(at: source),
              finalTarget.path == expectedExternal.path,
              try manifestStore.load(on: URL(fileURLWithPath: volume.path)).items.contains(where: {
                  $0.kind == .application &&
                  URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == source.path &&
                  URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path == expectedExternal.path
              }) else {
            throw MacBayError.manifestFailed(
                path: MacBayPaths.manifestURL(on: URL(fileURLWithPath: volume.path)).path,
                details: "The app was copied, but the final symlink or manifest could not be verified. The update record is preserved."
            )
        }

        try updateWorkflowStore.remove(appName: record.appName)
        return UpdateWorkflowReport(
            operation: "finish",
            record: record,
            currentVersion: metadata.version,
            currentBuild: metadata.build,
            migration: nil,
            dryRun: false,
            messages: [
                "Re-externalized \(record.appName) to \(volume.path).",
                "Version: \(record.originalVersion ?? "Unknown") → \(metadata.version ?? "Unknown").",
                "Future app updates should start with 'mb update begin \(record.appName)'."
            ]
        )
    }

    /// Runs Kiro's supported updater while the MacBay-managed bundle is local.
    /// Any failure after begin leaves the local bundle and workflow record for retry.
    public func runKiroUpdate(
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> UpdateWorkflowReport {
        let appName = "Kiro CLI.app"
        let localApp = applicationsDirectory.appendingPathComponent(appName, isDirectory: true)
        let preview = try beginAppUpdate(appName: localApp.path, dryRun: true, progress: progress)
        guard preview.record.bundleIdentifier == "com.amazon.codewhisperer" else {
            throw MacBayError.unsupportedOperation(
                "The managed updater only supports Kiro CLI (com.amazon.codewhisperer)."
            )
        }

        if dryRun {
            return UpdateWorkflowReport(
                operation: "run",
                record: preview.record,
                currentVersion: preview.currentVersion,
                currentBuild: preview.currentBuild,
                migration: preview.migration,
                dryRun: true,
                messages: [
                    "Will restore Kiro CLI, disable its background updater, run 'kiro-cli update --non-interactive', verify it, then return it to the original volume."
                ]
            )
        }

        _ = try beginAppUpdate(appName: localApp.path, dryRun: false, progress: progress)
        let cli = localApp.appendingPathComponent("Contents/MacOS/kiro-cli")
        do {
            let settings = try commandRunner.run(cli.path, arguments: ["settings", "app.disableAutoupdates", "true"])
            guard settings.status == 0 else {
                throw MacBayError.commandFailed(
                    executable: cli.path,
                    status: settings.status,
                    details: settings.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            let settingsCheck = try commandRunner.run(cli.path, arguments: ["settings", "list", "--format", "json"])
            guard settingsCheck.status == 0,
                  let settingsData = settingsCheck.standardOutput.data(using: .utf8),
                  let settingsJSON = try? JSONSerialization.jsonObject(with: settingsData),
                  Self.hasDisabledKiroAutoUpdates(settingsJSON) else {
                throw MacBayError.unsupportedOperation(
                    "Kiro did not confirm app.disableAutoupdates=true. The app remains in /Applications and its update record is preserved."
                )
            }

            let update = try commandRunner.run(cli.path, arguments: ["update", "--non-interactive"], heartbeat: {
                progress?(.copying)
            })
            guard update.status == 0 else {
                throw MacBayError.commandFailed(
                    executable: cli.path,
                    status: update.status,
                    details: update.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let versionResult = try commandRunner.run(cli.path, arguments: ["--version"])
            guard versionResult.status == 0 else {
                throw MacBayError.commandFailed(
                    executable: cli.path,
                    status: versionResult.status,
                    details: versionResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            let actual = try appBundleMetadata(at: localApp)
            guard let expectedVersion = actual.version, !expectedVersion.isEmpty,
                  versionResult.standardOutput.contains(expectedVersion) else {
                throw MacBayError.unsupportedOperation(
                    "Kiro CLI reported '\(versionResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))', which does not match the installed bundle version '\(actual.version ?? "unknown")'. The app remains in /Applications."
                )
            }

            let finished = try finishAppUpdate(appName: appName, dryRun: false, progress: progress)
            let result = UpdateWorkflowReport(
                operation: "run",
                record: finished.record,
                currentVersion: finished.currentVersion,
                currentBuild: finished.currentBuild,
                migration: finished.migration,
                dryRun: false,
                messages: [
                    "Kiro background updates are disabled.",
                    "Kiro CLI updated and verified at version \(actual.version!).",
                    "The app was returned to its original MacBay volume."
                ]
            )
            recordOperation(command: "update run", subject: appName, outcome: .success)
            return result
        } catch {
            recordOperation(
                command: "update run",
                subject: appName,
                outcome: .failure,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    private static func hasDisabledKiroAutoUpdates(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["app.disableAutoupdates"] as? Bool == true { return true }
            if let app = dictionary["app"] as? [String: Any],
               app["disableAutoupdates"] as? Bool == true { return true }
            return dictionary.values.contains(where: hasDisabledKiroAutoUpdates)
        }
        if let array = value as? [Any] {
            return array.contains(where: hasDisabledKiroAutoUpdates)
        }
        return false
    }

    public func recoverLocalApp(
        appName: String,
        from candidatePath: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        dryRun: Bool
    ) throws -> LocalAppRecoveryReport {
        do {
            let report = try localAppRecoveryManager.recover(
                appName: appName,
                from: candidatePath,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier,
                dryRun: dryRun
            )
            recordOperation(
                command: "recover",
                subject: report.appName,
                outcome: .success,
                dryRun: dryRun
            )
            return report
        } catch {
            recordOperation(
                command: "recover",
                subject: appName,
                outcome: .failure,
                detail: error.localizedDescription,
                dryRun: dryRun
            )
            throw error
        }
    }

    public func updateStatus() throws -> [UpdateWorkflowRecord] {
        try updateWorkflowStore.records().sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private func updateWorkflowVolume(for record: UpdateWorkflowRecord) throws -> StorageVolume {
        let configured = DefaultVolume(
            path: record.volumePath,
            name: record.volumeName,
            uuid: record.volumeUUID,
            savedAt: record.startedAt
        )
        let volume: StorageVolume
        switch volumeManager.availability(of: configured) {
        case let .mounted(mounted, _):
            volume = mounted
        case .notMounted:
            throw MacBayError.invalidVolume(
                "The original update volume '\(record.volumeName)' is not mounted. Reconnect it and retry 'mb update finish \(record.appName)'."
            )
        case let .ineligible(path, reason):
            throw MacBayError.invalidVolume("The original update volume at \(path) is not eligible: \(reason)")
        }

        let info = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        guard let uuid = info.volumeUUID,
              uuid.caseInsensitiveCompare(record.volumeUUID) == .orderedSame else {
            throw MacBayError.invalidVolume(
                "The volume at \(volume.path) does not match the original update volume UUID. The local app and workflow record were preserved."
            )
        }
        return volume
    }

    private func macBayVolumePath(for appURL: URL, appName: String) throws -> String {
        let components = appURL.standardizedFileURL.pathComponents
        guard let macBayIndex = components.firstIndex(of: MacBayPaths.externalRootName),
              macBayIndex > 0,
              components.count == macBayIndex + 3,
              components[macBayIndex + 1] == "Applications",
              components[macBayIndex + 2] == appName else {
            throw MacBayError.unsupportedOperation(
                "The app must point directly to <volume>/MacBay/Applications/\(appName)."
            )
        }
        return "/" + components.dropFirst().prefix(macBayIndex - 1).joined(separator: "/")
    }

    private func appBundleMetadata(at url: URL) throws -> (bundleIdentifier: String?, version: String?, build: String?) {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            throw MacBayError.invalidApplication("Missing or unreadable Contents/Info.plist: \(url.path)")
        }
        return (
            plist["CFBundleIdentifier"] as? String,
            plist["CFBundleShortVersionString"] as? String,
            plist["CFBundleVersion"] as? String
        )
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func symlinkDestination(at url: URL) -> URL? {
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: rawTarget, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    public func xcode(
        volumePath: String?,
        options: XcodeDoctorOptions = XcodeDoctorOptions(),
        dryRun: Bool
    ) throws -> XcodeDoctorReport {
        let selection = try selectVolume(path: volumePath)
        return try xcodeDoctor.run(on: URL(fileURLWithPath: selection.volume.path), options: options, dryRun: dryRun)
    }

    public func move(
        path: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.selectingVolume)
        let selection = try selectVolume(path: volumePath)
        return try directoryMover.move(
            path: path,
            on: URL(fileURLWithPath: selection.volume.path),
            dryRun: dryRun,
            progress: progress
        )
    }

    public func unmove(
        path: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.selectingVolume)
        let volume: URL?
        if let volumePath {
            let selected = try volumeManager.resolveExternalVolume(path: volumePath)
            volume = URL(fileURLWithPath: selected.path)
        } else {
            volume = nil
        }
        return try directoryMover.unmove(path: path, from: volume, dryRun: dryRun, progress: progress)
    }

    public func teardown(
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> TeardownReport {
        try teardownManager.execute(volumePath: volumePath, dryRun: dryRun, progress: progress)
    }

    public func cache(volumePath: String?, dryRun: Bool, reset: Bool) throws -> CacheReport {
        if reset {
            return try cacheManager.reset(dryRun: dryRun)
        }
        let selection = try selectVolume(path: volumePath)
        return try cacheManager.enable(on: URL(fileURLWithPath: selection.volume.path), dryRun: dryRun)
    }

    public func scanPurge(options: PurgeOptions = PurgeOptions()) -> [PurgeItem] {
        purgeEngine.scan(options: options)
    }

    public func purge(
        items: [PurgeItem],
        options: PurgeOptions = PurgeOptions(),
        dryRun: Bool
    ) throws -> PurgeReport {
        try purgeEngine.execute(items: items, options: options, dryRun: dryRun)
    }

    public func purge(options: PurgeOptions = PurgeOptions(), dryRun: Bool) throws -> PurgeReport {
        let items = purgeEngine.scan(options: options)
        return try purge(items: items, options: options, dryRun: dryRun)
    }

    public func initialize(
        volumePath: String? = nil,
        chooser: (([StorageVolume]) throws -> Int)? = nil,
        confirmReplace: ((DefaultVolume, StorageVolume) throws -> Void)? = nil
    ) throws -> InitReport {
        let volume = try initializeVolume(path: volumePath, chooser: chooser)
        let config = try configStore.load()

        if let previous = config.defaultVolume,
           previous.path.caseInsensitiveCompare(volume.path) != .orderedSame {
            try confirmReplace?(previous, volume)
        }

        let uuid = (try? volumeManager.diskInfoProvider.diskInfo(for: volume.path))?.volumeUUID ?? nil
        let entry = DefaultVolume(
            path: volume.path,
            name: volume.name,
            uuid: uuid,
            savedAt: macBayTimestamp()
        )
        try configStore.save(MacBayConfig(version: MacBayConfig.currentVersion, defaultVolume: entry))

        return InitReport(
            volume: volume,
            configPath: configStore.configURL.path,
            previousDefault: config.defaultVolume,
            replaced: config.defaultVolume != nil
        )
    }

    public func showConfig() throws -> ConfigReport {
        ConfigReport(
            configPath: configStore.configURL.path,
            defaultVolume: try configStore.load().defaultVolume
        )
    }

    public func resetConfig() throws -> ConfigReport {
        ConfigReport(
            configPath: configStore.configURL.path,
            removedVolume: try configStore.reset()
        )
    }

    private func initializeVolume(
        path: String?,
        chooser: (([StorageVolume]) throws -> Int)?
    ) throws -> StorageVolume {
        if let path {
            return try volumeManager.resolveExternalVolume(path: path)
        }

        let eligibleVolumes = try volumeManager.externalVolumes()
        if eligibleVolumes.isEmpty {
            throw MacBayError.invalidVolume(
                "No eligible external APFS volume was found under /Volumes. Connect an external APFS volume and try again."
            )
        }
        if eligibleVolumes.count == 1 {
            return eligibleVolumes[0]
        }

        guard let chooser else {
            let names = eligibleVolumes.map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
            throw MacBayError.unsupportedOperation(
                "Multiple eligible external volumes found: \(names). Specify --volume <path> (interactive selection requires a terminal)."
            )
        }

        let index = try chooser(eligibleVolumes)
        guard eligibleVolumes.indices.contains(index) else {
            throw MacBayError.cancelled
        }
        return eligibleVolumes[index]
    }

    private func mountedConfiguredVolume() -> StorageVolume? {
        guard let configured = try? configStore.load().defaultVolume else { return nil }
        return try? volumeManager.resolveExternalVolume(path: nil, configuredDefault: configured).volume
    }

    private func selectVolume(path: String?) throws -> VolumeSelection {
        if let path {
            return try volumeManager.resolveExternalVolume(path: path, configuredDefault: nil)
        }
        return try volumeManager.resolveExternalVolume(
            path: nil,
            configuredDefault: try configStore.load().defaultVolume
        )
    }
}
