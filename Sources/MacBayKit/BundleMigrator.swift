import Foundation

public struct BundleMigrator {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let directoryMigrator: DirectoryMigrator
    private let processInspector: ProcessInspector
    private let manifestStore: ManifestStore
    private let sizeCalculator: FileSizeCalculator
    private let volumeManager: VolumeManager
    private let appInspector: AppInspector
    private let spaceEstimator: SpaceEstimator

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        appInspector: AppInspector? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.directoryMigrator = DirectoryMigrator(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
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
        self.appInspector = appInspector ?? AppInspector(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
    }

    public func dock(
        appName: String,
        on volume: URL,
        dryRun: Bool,
        force: Bool = false
    ) throws -> MigrationResult {
        // 1. 앱 경로 검증
        let source = MacBayPaths.applicationURL(named: appName)
        guard source.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(source.path)
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.pathMissing(source.path)
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) == nil else {
            throw MacBayError.applicationAlreadyDocked(source.path)
        }

        // 2. 호환성 검사
        let assessment = appInspector.assess(bundleURL: source)
        if assessment.grade == .blocked {
            throw MacBayError.compatibilityBlocked(path: source.path, assessment: assessment)
        }
        if assessment.grade == .popupRisk && !dryRun && !force {
            throw MacBayError.forceRequired(path: source.path, assessment: assessment)
        }

        // 3. 볼륨 검증
        let volumeInfo = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        let check = volumeManager.eligibilityCheck(for: volumeInfo)
        guard check.isEligible else {
            if volumeInfo.isInternal {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(volume.path)")
            } else {
                throw MacBayError.invalidVolume("\(check.reason ?? "Volume is not eligible"): \(volume.path)")
            }
        }

        // 4. 프로세스/SQLite 잠금 검사
        try processInspector.assertSafeToMove(path: source)

        // 5. 코드서명 검사
        try verifyCodeSignature(at: source)

        // 6. 복사·재검증
        let destination = MacBayPaths.applicationsRoot(on: volume)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MacBayError.destinationExists(destination.path)
        }

        let sizeBytes = try sizeCalculator.size(of: source)
        var messages: [String] = []
        if assessment.grade == .popupRisk {
            messages.append("Warning: Application is flagged with popup risks (\(assessment.reasons.joined(separator: ", ")))")
        }

        let sourceVolumeInfo = try? volumeManager.diskInfoProvider.diskInfo(for: source.path)
        let estimate = spaceEstimator.estimate(
            copyBytes: sizeBytes,
            destinationVolume: volume,
            internalFreedBytes: sourceVolumeInfo?.isInternal == true ? sizeBytes : nil
        )
        messages.append(contentsOf: estimate.reportLines())

        if dryRun {
            messages.append("Dry run: no files were changed")
            return MigrationResult(
                operation: "dock",
                name: source.lastPathComponent,
                sourcePath: source.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: true,
                messages: messages,
                compatibility: assessment
            )
        }

        // 실행 직전에 여유 공간을 다시 확인하고, 부족하면 복사·링크 변경 전에 중단한다.
        try spaceEstimator.requireSufficientSpace(copyBytes: sizeBytes, destinationVolume: volume)

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try runDitto(from: source, to: destination)
            try verifyCodeSignature(at: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }

        // 7. 심볼릭 링크
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

        // 8. manifest 저장
        let item = DockedItem(
            name: source.lastPathComponent,
            sourcePath: source.path,
            externalPath: destination.path,
            sizeBytes: sizeBytes,
            kind: .application,
            dockedAt: macBayTimestamp()
        )
        try manifestStore.updating(on: volume) { manifest in
            manifest.items.removeAll { $0.sourcePath == item.sourcePath }
            manifest.items.append(item)
        }

        // 9. Dock 갱신
        let dockWarnings = refreshDock(for: source)
        messages.append("Migration completed")
        messages.append(contentsOf: dockWarnings)

        return MigrationResult(
            operation: "dock",
            name: source.lastPathComponent,
            sourcePath: source.path,
            destinationPath: destination.path,
            sizeBytes: sizeBytes,
            dryRun: false,
            messages: messages,
            compatibility: assessment
        )
    }

    public func undock(appName: String, from volume: URL?, dryRun: Bool) throws -> MigrationResult {
        let source = MacBayPaths.applicationURL(named: appName)
        guard source.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(source.path)
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.pathMissing(source.path)
        }
        guard let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: source.path) else {
            throw MacBayError.unsupportedOperation("Application is not managed by MacBay: \(source.path)")
        }

        let destination = URL(fileURLWithPath: linkDestination).standardizedFileURL
        guard destination.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: destination.path) else {
            throw MacBayError.pathMissing(destination.path)
        }
        let destinationComponents = destination.pathComponents
        guard let macBayIndex = destinationComponents.firstIndex(of: MacBayPaths.externalRootName),
              destinationComponents.indices.contains(macBayIndex + 1),
              destinationComponents[macBayIndex + 1] == "Applications" else {
            throw MacBayError.unsupportedOperation("Symlink target is outside MacBay storage: \(destination.path)")
        }
        if let volume {
            let expected = MacBayPaths.applicationsRoot(on: volume)
                .appendingPathComponent(source.lastPathComponent)
                .standardizedFileURL
            guard expected.path == destination.path else {
                throw MacBayError.invalidVolume("Symlink target is not on the selected volume: \(destination.path)")
            }
        }

        try processInspector.assertSafeToMove(path: destination)
        try verifyCodeSignature(at: destination)
        let sizeBytes = try sizeCalculator.size(of: destination)
        let internalVolume = URL(fileURLWithPath: "/")
        let estimate = spaceEstimator.estimate(copyBytes: sizeBytes, destinationVolume: internalVolume)
        let messages = estimate.reportLines()
        if dryRun {
            return MigrationResult(
                operation: "undock",
                name: source.lastPathComponent,
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
        try runDitto(from: destination, to: restored)
        do {
            try verifyCodeSignature(at: restored)
            try fileManager.removeItem(at: source)
            try fileManager.moveItem(at: restored, to: source)
            try fileManager.removeItem(at: destination)
        } catch {
            if fileManager.fileExists(atPath: restored.path) {
                try? fileManager.removeItem(at: restored)
            }
            throw error
        }

        if let volume = volume ?? inferredVolume(for: destination) {
            try manifestStore.updating(on: volume) { manifest in
                manifest.items.removeAll { $0.sourcePath == source.path || $0.externalPath == destination.path }
            }
        }

        let dockWarnings = refreshDock(for: source)
        return MigrationResult(
            operation: "undock",
            name: source.lastPathComponent,
            sourcePath: destination.path,
            destinationPath: source.path,
            sizeBytes: sizeBytes,
            dryRun: false,
            messages: messages + ["Migration completed"] + dockWarnings
        )
    }

    private func verifyCodeSignature(at url: URL) throws {
        let result = try commandRunner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", url.path]
        )
        guard result.status == 0 else {
            let details = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacBayError.signatureVerificationFailed(path: url.path, details: details)
        }
    }

    private func runDitto(from source: URL, to destination: URL) throws {
        let result = try commandRunner.run(
            "/usr/bin/ditto",
            arguments: ["--rsrc", "--extattr", "--acl", source.path, destination.path]
        )
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/bin/ditto",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func inferredVolume(for destination: URL) -> URL? {
        let components = destination.standardizedFileURL.pathComponents
        guard let macBayIndex = components.firstIndex(of: MacBayPaths.externalRootName), macBayIndex > 0 else {
            return nil
        }
        let volumeComponents = components.dropFirst().prefix(macBayIndex - 1)
        return URL(fileURLWithPath: "/" + volumeComponents.joined(separator: "/"))
    }

    private func refreshDock(for appURL: URL) -> [String] {
        var warnings: [String] = []
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fileManager.isExecutableFile(atPath: lsregisterPath) {
            do {
                let result = try commandRunner.run(lsregisterPath, arguments: ["-f", appURL.path])
                if result.status != 0 {
                    warnings.append("Warning: lsregister failed with status \(result.status)")
                }
            } catch {
                warnings.append("Warning: lsregister failed: \(error.localizedDescription)")
            }
        }
        do {
            let result = try commandRunner.run("/usr/bin/killall", arguments: ["Dock"])
            if result.status != 0 {
                warnings.append("Warning: killall Dock failed with status \(result.status)")
            }
        } catch {
            warnings.append("Warning: killall Dock failed: \(error.localizedDescription)")
        }
        return warnings
    }
}
