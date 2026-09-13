import Foundation

/// Moves arbitrary directories (game libraries, VMs, datasets, ...) to external
/// storage and restores them, recording each item in the volume manifest.
public struct DirectoryMoveManager {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let processInspector: ProcessInspector
    private let manifestStore: ManifestStore
    private let sizeCalculator: FileSizeCalculator
    private let volumeManager: VolumeManager
    private let spaceEstimator: SpaceEstimator
    private let symlinkResolver: SymlinkResolver

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.processInspector = ProcessInspector(
            commandRunner: commandRunner,
            fileManager: fileManager
        )
        self.manifestStore = ManifestStore(fileManager: fileManager)
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.spaceEstimator = SpaceEstimator(diskInfoProvider: self.volumeManager.diskInfoProvider)
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
    }

    /// Paths that must never be externalized, including everything below them.
    private static let blockedRoots: [String] = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var",
        "/private", "/opt", "/Applications", "/Volumes", "/dev", "/tmp", "/cores"
    ]

    /// Paths blocked only at their exact root — their subdirectories are movable.
    private static let blockedExactPaths: [String] = ["/Users"]

    public func move(
        path: String,
        on volume: URL,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.validating)
        let source = MacBayPaths.expandedURL(path)

        guard fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.pathMissing(source.path)
        }
        guard !isSymbolicLink(source) else {
            throw MacBayError.unsupportedOperation("Path is already a symbolic link: \(source.path)")
        }
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            throw MacBayError.unsupportedOperation("Only directories can be moved: \(source.path)")
        }
        guard source.pathExtension.lowercased() != "app" else {
            throw MacBayError.unsupportedOperation(
                "Application bundles use 'mb dock' for compatibility checks and Dock refresh: \(source.path)"
            )
        }
        try requireMovableLocation(source)

        let sourceInfo = try volumeManager.diskInfoProvider.diskInfo(for: source.path)
        guard sourceInfo.isInternal else {
            throw MacBayError.unsupportedOperation(
                "Path is already on a non-internal volume (\(sourceInfo.mountPoint)): \(source.path)"
            )
        }

        // 볼륨 검증
        let volumeInfo = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        let check = volumeManager.eligibilityCheck(for: volumeInfo)
        guard check.isEligible else {
            if volumeInfo.isInternal {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(volume.path)")
            }
            throw MacBayError.invalidVolume("\(check.reason ?? "Volume is not eligible"): \(volume.path)")
        }

        let destination = MacBayPaths.dataRoot(on: volume)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MacBayError.destinationExists(destination.path)
        }

        progress?(.checkingProcesses)
        try processInspector.assertSafeToMove(path: source)

        progress?(.inspectingStorage)
        let sizeBytes = try sizeCalculator.size(of: source)
        var messages: [String] = []
        let estimate = spaceEstimator.estimate(
            copyBytes: sizeBytes,
            destinationVolume: volume,
            internalFreedBytes: sizeBytes
        )
        messages.append(contentsOf: estimate.reportLines())

        if dryRun {
            messages.append("Dry run: no files were changed")
            return MigrationResult(
                operation: "move",
                name: source.lastPathComponent,
                sourcePath: source.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: true,
                messages: messages
            )
        }

        // 실행 직전에 여유 공간을 다시 확인하고, 부족하면 복사·링크 변경 전에 중단한다.
        try spaceEstimator.requireSufficientSpace(copyBytes: sizeBytes, destinationVolume: volume)

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            progress?(.copying)
            try runDitto(from: source, to: destination, totalBytes: sizeBytes, progress: progress)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }

        progress?(.updatingLink)
        try replaceSourceWithSymlink(source: source, destination: destination)

        progress?(.savingManifest)
        let item = DockedItem(
            name: source.lastPathComponent,
            sourcePath: source.path,
            externalPath: destination.path,
            sizeBytes: sizeBytes,
            kind: .directory,
            dockedAt: macBayTimestamp()
        )
        try manifestStore.updating(on: volume) { manifest in
            manifest.items.removeAll { $0.sourcePath == item.sourcePath }
            manifest.items.append(item)
        }

        messages.append("Migration completed")
        return MigrationResult(
            operation: "move",
            name: source.lastPathComponent,
            sourcePath: source.path,
            destinationPath: destination.path,
            sizeBytes: sizeBytes,
            dryRun: false,
            messages: messages
        )
    }

    /// Restores a moved directory given its original (now symlinked) path.
    public func unmove(
        path: String,
        from volume: URL?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.validating)
        let source = MacBayPaths.expandedURL(path)
        guard isSymbolicLink(source) else {
            throw MacBayError.unsupportedOperation("Path is not a MacBay link: \(source.path)")
        }

        let target: URL
        switch symlinkResolver.resolve(at: source) {
        case let .resolved(resolved, _, _):
            target = resolved.standardizedFileURL
        case let .broken(targetPath, _), let .circular(targetPath, _):
            throw MacBayError.pathMissing(
                "Link target is unavailable: \(targetPath). Reconnect the volume or run 'mb doctor'."
            )
        }

        guard fileManager.fileExists(atPath: target.path) else {
            throw MacBayError.pathMissing(target.path)
        }

        // 기록이 있으면 기록을 따르고, 없으면 MacBay 표준 Data 레이아웃만 허용한다.
        var record: (item: DockedItem, volume: URL)?
        if let found = findRecord(for: source) {
            record = found
        } else {
            guard let inferred = inferredVolume(for: target),
                  isUnderMacBayDataRoot(target, on: inferred) else {
                throw MacBayError.unsupportedOperation(
                    "Link target is outside MacBay storage: \(target.path)"
                )
            }
        }

        if let volume {
            let expectedVolumePath = record?.volume.path
                ?? inferredVolume(for: target)?.path
            guard expectedVolumePath == volume.path else {
                throw MacBayError.invalidVolume(
                    "Link target is not on the selected volume: \(target.path)"
                )
            }
        }

        let item = record?.item ?? DockedItem(
            name: source.lastPathComponent,
            sourcePath: source.path,
            externalPath: target.path,
            sizeBytes: 0,
            kind: .directory,
            dockedAt: ""
        )
        return try restore(
            item: item,
            volume: record?.volume ?? inferredVolume(for: target) ?? volume,
            dryRun: dryRun,
            progress: progress
        )
    }

    /// Restores one recorded directory item: copies the external copy back to its
    /// recorded source path, removes the link and the external copy, and drops the record.
    @discardableResult
    public func restore(
        item: DockedItem,
        volume: URL?,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        let source = URL(fileURLWithPath: item.sourcePath).standardizedFileURL
        let destination = URL(fileURLWithPath: item.externalPath).standardizedFileURL

        progress?(.validating)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw MacBayError.pathMissing(destination.path)
        }
        guard isSymbolicLink(source) || !fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.unsupportedOperation(
                "Local data exists at \(source.path); inspect with 'mb doctor' before restoring."
            )
        }

        progress?(.checkingProcesses)
        try processInspector.assertSafeToMove(path: destination)

        progress?(.inspectingStorage)
        let sizeBytes = try sizeCalculator.size(of: destination)
        let internalVolume = URL(fileURLWithPath: "/")
        let estimate = spaceEstimator.estimate(copyBytes: sizeBytes, destinationVolume: internalVolume)
        let messages = estimate.reportLines()
        if dryRun {
            return MigrationResult(
                operation: "unmove",
                name: item.name,
                sourcePath: destination.path,
                destinationPath: source.path,
                sizeBytes: sizeBytes,
                dryRun: true,
                messages: messages + ["Dry run: no files were changed"]
            )
        }

        // 실행 직전에 내장 볼륨 여유 공간을 다시 확인하고, 부족하면 복사 전에 중단한다.
        try spaceEstimator.requireSufficientSpace(copyBytes: sizeBytes, destinationVolume: internalVolume)

        let restored = source.deletingLastPathComponent().appendingPathComponent(
            ".\(source.lastPathComponent).macbay-restore-\(UUID().uuidString)"
        )
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress?(.copying)
        try runDitto(from: destination, to: restored, totalBytes: sizeBytes, progress: progress)

        // 기존 링크를 제거한 뒤 복원본 이동이 실패하면 원래 링크를 되살려 외장 원본으로 다시 연결한다.
        progress?(.updatingLink)
        let linkDestination = (try? fileManager.destinationOfSymbolicLink(atPath: source.path))
            ?? destination.path
        if fileManager.fileExists(atPath: source.path) || isSymbolicLink(source) {
            try fileManager.removeItem(at: source)
        }
        do {
            try fileManager.moveItem(at: restored, to: source)
        } catch {
            try? fileManager.removeItem(at: restored)
            if !fileManager.fileExists(atPath: source.path) {
                try? fileManager.createSymbolicLink(
                    atPath: source.path,
                    withDestinationPath: linkDestination
                )
            }
            throw error
        }
        try fileManager.removeItem(at: destination)

        if let volume = volume ?? inferredVolume(for: destination) {
            progress?(.savingManifest)
            try manifestStore.updating(on: volume) { manifest in
                manifest.items.removeAll {
                    $0.sourcePath == item.sourcePath || $0.externalPath == item.externalPath
                }
            }
        }

        return MigrationResult(
            operation: "unmove",
            name: item.name,
            sourcePath: destination.path,
            destinationPath: source.path,
            sizeBytes: sizeBytes,
            dryRun: false,
            messages: messages + ["Migration completed"]
        )
    }

    /// Removes a managed cache link and recreates an empty directory in its place.
    /// The external copy under MacBay/Caches is kept as an unmanaged archive.
    @discardableResult
    public func unlinkCache(source: URL, target: URL, dryRun: Bool) throws -> MigrationResult {
        guard isSymbolicLink(source) else {
            throw MacBayError.unsupportedOperation("Path is not a symbolic link: \(source.path)")
        }
        if !dryRun {
            try fileManager.removeItem(at: source)
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        }
        return MigrationResult(
            operation: "unlink cache",
            name: source.lastPathComponent,
            sourcePath: source.path,
            destinationPath: target.path,
            sizeBytes: 0,
            dryRun: dryRun,
            messages: [
                "Removed link and recreated an empty directory",
                "External copy retained at \(target.path)"
            ]
        )
    }

    private func requireMovableLocation(_ source: URL) throws {
        let path = source.standardizedFileURL.path
        let homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let blockedExact = Self.blockedExactPaths + [homePath, homePath + "/Library"]
        for root in blockedExact where path == root {
            throw MacBayError.unsupportedOperation(
                "Refusing to externalize a protected location: \(path)"
            )
        }
        for root in Self.blockedRoots {
            if path == root || path.hasPrefix(root + "/") {
                throw MacBayError.unsupportedOperation(
                    "Refusing to externalize a protected location: \(path)"
                )
            }
        }
    }

    private func findRecord(for source: URL) -> (item: DockedItem, volume: URL)? {
        let standardizedSource = source.standardizedFileURL.path
        guard let volumes = try? volumeManager.externalVolumes() else { return nil }
        for volume in volumes {
            let volumeURL = URL(fileURLWithPath: volume.path)
            guard let manifest = try? manifestStore.load(on: volumeURL) else { continue }
            if let item = manifest.items.first(where: { item in
                item.kind == .directory &&
                URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
                    .caseInsensitiveCompare(standardizedSource) == .orderedSame
            }) {
                return (item, volumeURL)
            }
        }
        return nil
    }

    private func isUnderMacBayDataRoot(_ target: URL, on volume: URL) -> Bool {
        let root = MacBayPaths.dataRoot(on: volume).standardizedFileURL.path
        return target.standardizedFileURL.path.hasPrefix(root + "/")
    }

    private func inferredVolume(for destination: URL) -> URL? {
        let components = destination.standardizedFileURL.pathComponents
        guard let macBayIndex = components.firstIndex(of: MacBayPaths.externalRootName), macBayIndex > 0 else {
            return nil
        }
        let volumeComponents = components.dropFirst().prefix(macBayIndex - 1)
        return URL(fileURLWithPath: "/" + volumeComponents.joined(separator: "/"))
    }

    private func runDitto(from source: URL, to destination: URL, totalBytes: UInt64, progress: ProgressHandler?) throws {
        var sampler = CopyProgressSampler(destination: destination, totalBytes: totalBytes)
        let result = try commandRunner.run(
            "/usr/bin/ditto",
            arguments: ["--rsrc", "--extattr", "--acl", source.path, destination.path],
            heartbeat: {
                if let progress, let sample = sampler.sample() { progress(.copyProgress(sample)) }
            }
        )
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/bin/ditto",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func replaceSourceWithSymlink(source: URL, destination: URL) throws {
        let backup = source.deletingLastPathComponent().appendingPathComponent(
            ".\(source.lastPathComponent).macbay-\(UUID().uuidString)"
        )
        try fileManager.moveItem(at: source, to: backup)
        do {
            try fileManager.createSymbolicLink(atPath: source.path, withDestinationPath: destination.path)
            try fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: source)
            }
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: backup, to: source)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
