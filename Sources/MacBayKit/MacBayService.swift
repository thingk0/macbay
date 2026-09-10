import Foundation

public struct MacBayService {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let manifestStore: ManifestStore
    private let scanner: AppScanner
    private let bundleMigrator: BundleMigrator
    private let xcodeDoctor: XcodeDoctor
    private let cacheManager: CacheManager

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil
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
        force: Bool = false
    ) throws -> MigrationResult {
        let selection = try selectVolume(path: volumePath)
        return try bundleMigrator.dock(
            appName: appName,
            on: URL(fileURLWithPath: selection.volume.path),
            dryRun: dryRun,
            force: force
        )
    }

    public func undock(appName: String, volumePath: String?, dryRun: Bool) throws -> MigrationResult {
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
            dryRun: dryRun
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
