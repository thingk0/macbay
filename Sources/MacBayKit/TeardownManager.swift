import Foundation

/// Reverts everything MacBay manages: restores recorded applications and
/// directories, removes managed cache links, clears the ~/.zshrc cache block,
/// and forgets the saved default volume. Individual item failures are collected
/// instead of aborting the run. The MacBay directory itself is left on each
/// external volume so retained backups and unrecorded data are never deleted.
public struct TeardownManager {
    private let fileManager: FileManager
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let manifestStore: ManifestStore
    private let bundleMigrator: BundleMigrator
    private let directoryMover: DirectoryMoveManager
    private let cacheManager: CacheManager
    private let symlinkResolver: SymlinkResolver
    private let developerCacheTargets: [DeveloperCacheTarget]?

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil,
        cacheManager: CacheManager? = nil,
        developerCacheTargets: [DeveloperCacheTarget]? = nil
    ) {
        self.fileManager = fileManager
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.manifestStore = ManifestStore(fileManager: fileManager)
        self.bundleMigrator = BundleMigrator(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager
        )
        self.directoryMover = DirectoryMoveManager(
            fileManager: fileManager,
            commandRunner: commandRunner,
            volumeManager: self.volumeManager
        )
        self.cacheManager = cacheManager ?? CacheManager(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
        self.developerCacheTargets = developerCacheTargets
    }

    public func execute(
        volumePath: String? = nil,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> TeardownReport {
        var restored: [MigrationResult] = []
        var unlinkedCaches: [MigrationResult] = []
        var failures: [TeardownFailure] = []
        var notes: [String] = []
        var handledSources: Set<String> = []

        // 1. 대상 볼륨 결정: 명시된 볼륨이 없으면 연결된 모든 적격 외장 볼륨.
        progress?(.selectingVolume)
        var volumes: [URL] = []
        if let volumePath {
            let selected = try volumeManager.resolveExternalVolume(path: volumePath)
            volumes = [URL(fileURLWithPath: selected.path)]
        } else {
            let (eligible, volumeWarnings) = try volumeManager.externalVolumesWithWarnings()
            volumes = eligible.map { URL(fileURLWithPath: $0.path) }
            notes.append(contentsOf: volumeWarnings)
            if eligible.isEmpty {
                notes.append("No eligible external volumes are mounted; recorded items could not be restored.")
            }
            if let configured = try? configStore.load().defaultVolume,
               case .notMounted = volumeManager.availability(of: configured) {
                notes.append(
                    "Default volume '\(configured.name)' (\(configured.path)) is not mounted; its managed items were not restored."
                )
            }
        }

        // 2. 기록된 항목 복원: 애플리케이션은 undock, 나머지는 디렉터리 복원.
        for volume in volumes {
            let manifest: DockManifest
            do {
                manifest = try manifestStore.load(on: volume)
            } catch {
                notes.append(
                    "Unable to load manifest for \(volume.path): \(error.localizedDescription). Its recorded items were not restored."
                )
                continue
            }
            for item in manifest.items {
                let sourceKey = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                handledSources.insert(sourceKey)
                do {
                    if item.kind == .application {
                        let result = try bundleMigrator.undock(
                            appName: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
                            from: volume,
                            dryRun: dryRun,
                            progress: progress
                        )
                        restored.append(result)
                    } else {
                        let result = try directoryMover.restore(
                            item: item,
                            volume: volume,
                            dryRun: dryRun,
                            progress: progress
                        )
                        restored.append(result)
                    }
                } catch {
                    let reason = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                    failures.append(TeardownFailure(path: item.sourcePath, reason: reason))
                }
            }
        }

        // 3. 기록 없이 링크만 남은 알려진 개발자 위치(xcode·cache 대상)를 정리한다.
        //    Caches 아래의 복사본은 재생성 가능하므로 링크만 제거하고 빈 디렉터리로 되돌린다.
        for target in developerCacheTargets ?? AppScanner.defaultDeveloperCacheTargets() {
            let source = target.path.standardizedFileURL
            let sourceKey = source.path
            guard !handledSources.contains(sourceKey) else { continue }
            guard isSymbolicLink(source) else { continue }
            handledSources.insert(sourceKey)

            guard case let .resolved(linkTarget, _, _) = symlinkResolver.resolve(at: source) else {
                failures.append(TeardownFailure(
                    path: source.path,
                    reason: "Link target is unavailable; remove the link manually."
                ))
                continue
            }
            let standardizedTarget = linkTarget.standardizedFileURL
            guard let volume = volumes.first(where: {
                standardizedTarget.path.hasPrefix(
                    MacBayPaths.externalRoot(on: $0).standardizedFileURL.path + "/"
                )
            }) else { continue }

            do {
                if standardizedTarget.path.hasPrefix(
                    MacBayPaths.cachesRoot(on: volume).standardizedFileURL.path + "/"
                ) {
                    unlinkedCaches.append(try directoryMover.unlinkCache(
                        source: source,
                        target: standardizedTarget,
                        dryRun: dryRun
                    ))
                } else {
                    let result = try directoryMover.restore(
                        item: DockedItem(
                            name: source.lastPathComponent,
                            sourcePath: source.path,
                            externalPath: standardizedTarget.path,
                            sizeBytes: 0,
                            kind: .directory,
                            dockedAt: ""
                        ),
                        volume: volume,
                        dryRun: dryRun,
                        progress: progress
                    )
                    restored.append(result)
                }
            } catch {
                let reason = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                failures.append(TeardownFailure(path: source.path, reason: reason))
            }
        }

        // 4. ~/.zshrc의 관리 블록과 저장된 기본 볼륨을 제거한다.
        let cacheBlockPresent = cacheManager.isManagedBlockPresent()
        if !dryRun, cacheBlockPresent {
            _ = try cacheManager.reset(dryRun: false)
        }
        let savedDefault = (try? configStore.load())?.defaultVolume
        if !dryRun {
            _ = try configStore.reset()
        }

        // 5. 외장 볼륨의 MacBay 디렉터리(백업 등)는 자동으로 지우지 않는다.
        for volume in volumes where fileManager.fileExists(atPath: MacBayPaths.externalRoot(on: volume).path) {
            notes.append(
                "MacBay data remains at \(MacBayPaths.externalRoot(on: volume).path) — backups and unrecorded data are preserved; delete it manually if unneeded."
            )
        }

        return TeardownReport(
            restored: restored,
            unlinkedCaches: unlinkedCaches,
            failures: failures,
            cacheConfigurationReset: cacheBlockPresent,
            defaultVolumeRemoved: savedDefault != nil,
            notes: notes,
            dryRun: dryRun
        )
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
