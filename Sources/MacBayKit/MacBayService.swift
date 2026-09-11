import Foundation

public struct MacBayService {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let manifestStore: ManifestStore
    private let scanner: AppScanner
    private let bundleMigrator: BundleMigrator
    private let appAdopter: AppAdopter
    public let adoptAppUseCase: any AdoptAppUseCaseProtocol
    public let repairAppUseCase: any RepairAppUseCaseProtocol
    private let xcodeDoctor: XcodeDoctor
    private let cacheManager: CacheManager

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil,
        adoptAppUseCase: (any AdoptAppUseCaseProtocol)? = nil,
        repairAppUseCase: (any RepairAppUseCaseProtocol)? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.manifestStore = ManifestStore(fileManager: fileManager)
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

    public func doctor(volumePath: String? = nil) throws -> DoctorReport {
        let checker = DoctorChecker(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: volumeManager,
            manifestStore: manifestStore,
            configStore: configStore
        )
        return try checker.check(volumePath: volumePath)
    }

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.selectingVolume)
        let selection = try selectVolume(path: volumePath)
        return try bundleMigrator.dock(
            appName: appName,
            on: URL(fileURLWithPath: selection.volume.path),
            dryRun: dryRun,
            force: force,
            progress: progress
        )
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
        try adoptAppUseCase.execute(plan: plan, force: force, progress: progress)
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
        try repairAppUseCase.execute(plan: plan, force: force, progress: progress)
    }

    public func rollbackRepair(
        appName: String,
        volumePath: String?,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> RepairExecutionResult {
        let selection = try selectVolume(path: volumePath)
        return try repairAppUseCase.rollback(
            appName: appName,
            on: URL(fileURLWithPath: selection.volume.path),
            progress: progress
        )
    }

    public func undock(appName: String, volumePath: String?, dryRun: Bool, progress: ProgressHandler? = nil) throws -> MigrationResult {
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
        return try bundleMigrator.undock(
            appName: appName,
            from: volume,
            fallbackVolume: fallbackVolume,
            dryRun: dryRun,
            progress: progress
        )
    }

    public func xcode(volumePath: String?, dryRun: Bool) throws -> XcodeDoctorReport {
        let selection = try selectVolume(path: volumePath)
        return try xcodeDoctor.run(on: URL(fileURLWithPath: selection.volume.path), dryRun: dryRun)
    }

    public func cache(volumePath: String?, dryRun: Bool, reset: Bool) throws -> CacheReport {
        if reset {
            return try cacheManager.reset(dryRun: dryRun)
        }
        let selection = try selectVolume(path: volumePath)
        return try cacheManager.enable(on: URL(fileURLWithPath: selection.volume.path), dryRun: dryRun)
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
            throw MacBayError.unsupportedOperation("Cancelled")
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
