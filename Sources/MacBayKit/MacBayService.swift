import Foundation

public struct MacBayService {
    private let fileManager: FileManager
    private let volumeManager: VolumeManager
    private let manifestStore: ManifestStore
    private let scanner: AppScanner
    private let bundleMigrator: BundleMigrator
    private let xcodeDoctor: XcodeDoctor
    private let cacheManager: CacheManager

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.fileManager = fileManager
        self.volumeManager = VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
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
            dockedItems: dockedItems.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            warnings: warnings
        )
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

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool = false
    ) throws -> MigrationResult {
        let volume = try volumeManager.resolveExternalVolume(path: volumePath)
        return try bundleMigrator.dock(
            appName: appName,
            on: URL(fileURLWithPath: volume.path),
            dryRun: dryRun,
            force: force
        )
    }

    public func undock(appName: String, volumePath: String?, dryRun: Bool) throws -> MigrationResult {
        let volume: URL?
        if let volumePath {
            let selected = try volumeManager.resolveExternalVolume(path: volumePath)
            volume = URL(fileURLWithPath: selected.path)
        } else {
            volume = nil
        }
        return try bundleMigrator.undock(appName: appName, from: volume, dryRun: dryRun)
    }

    public func xcode(volumePath: String?, dryRun: Bool) throws -> XcodeDoctorReport {
        let volume = try volumeManager.resolveExternalVolume(path: volumePath)
        return try xcodeDoctor.run(on: URL(fileURLWithPath: volume.path), dryRun: dryRun)
    }

    public func cache(volumePath: String?, dryRun: Bool, reset: Bool) throws -> CacheReport {
        if reset {
            return try cacheManager.reset(dryRun: dryRun)
        }
        let volume = try volumeManager.resolveExternalVolume(path: volumePath)
        return try cacheManager.enable(on: URL(fileURLWithPath: volume.path), dryRun: dryRun)
    }
}
