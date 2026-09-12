import Foundation
import Darwin

public struct AppAdopter {
    private enum AdoptMode {
        case alreadyAdopted
        case registerOnly
        case moveAndAdopt
    }

    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let volumeManager: VolumeManager
    private let manifestStore: ManifestStore
    private let symlinkResolver: SymlinkResolver
    private let appInspector: AppInspector
    private let processInspector: ProcessInspector
    private let sizeCalculator: FileSizeCalculator
    private let operationJournal: OperationJournal
    private let dockRefresher: DockRefresher

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        manifestStore: ManifestStore? = nil,
        appInspector: AppInspector? = nil,
        processInspector: ProcessInspector? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.manifestStore = manifestStore ?? ManifestStore(fileManager: fileManager)
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
        self.appInspector = appInspector ?? AppInspector(fileManager: fileManager, commandRunner: commandRunner)
        self.processInspector = processInspector ?? ProcessInspector(commandRunner: commandRunner, fileManager: fileManager)
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.operationJournal = OperationJournal(fileManager: fileManager)
        self.dockRefresher = DockRefresher(fileManager: fileManager, commandRunner: commandRunner)
    }

    public func adopt(
        appName: String,
        on volume: URL,
        dryRun: Bool,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> MigrationResult {
        progress?(.validating)
        // 1. 앱 경로 및 심볼릭 링크 검증
        let source = MacBayPaths.applicationURL(named: appName)
        guard source.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(source.path)
        }

        let rawLinkDestination: String
        do {
            rawLinkDestination = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        } catch {
            guard fileManager.fileExists(atPath: source.path) else {
                throw MacBayError.pathMissing(source.path)
            }
            throw MacBayError.unsupportedOperation(
                "Application is a local bundle, not a symbolic link: \(source.path). Use 'mb dock' to move local applications to external storage."
            )
        }

        let resolution = symlinkResolver.resolve(at: source)
        let target: URL
        switch resolution {
        case let .broken(targetPath, _):
            // 미완료 작업 기록이 있는지 확인하여 이미 대상 경로로 앱이 이동되었는지 복구 점검
            let destination = MacBayPaths.applicationsRoot(on: volume)
                .appendingPathComponent(source.lastPathComponent, isDirectory: true)
                .standardizedFileURL
            if let incomplete = operationJournal.load(for: source.lastPathComponent, on: volume),
               incomplete.originalExternalPath == rawLinkDestination,
               fileManager.fileExists(atPath: destination.path) {
                target = destination
            } else {
                throw MacBayError.pathMissing("Broken symlink at \(source.path): target \(targetPath) does not exist")
            }
        case let .circular(targetPath, _):
            throw MacBayError.unsupportedOperation("Circular symlink detected at \(source.path): \(targetPath)")
        case let .resolved(resolvedTarget, hops, _):
            if hops > 1 {
                throw MacBayError.unsupportedOperation(
                    "Multi-hop symlink detected (\(hops) hops) for \(source.path). Multi-hop links are not supported by adopt."
                )
            }
            target = resolvedTarget
        }

        guard target.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(target.path)
        }
        guard fileManager.fileExists(atPath: target.path) else {
            throw MacBayError.pathMissing(target.path)
        }

        // 2. 볼륨 검증
        let selectedVolumeInfo = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        let selectedCheck = volumeManager.eligibilityCheck(for: selectedVolumeInfo)
        guard selectedCheck.isEligible else {
            if selectedVolumeInfo.isInternal {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(volume.path)")
            } else {
                throw MacBayError.invalidVolume("\(selectedCheck.reason ?? "Volume is not eligible"): \(volume.path)")
            }
        }

        let targetDiskInfo: VolumeDiskInfo
        do {
            targetDiskInfo = try volumeManager.diskInfoProvider.diskInfo(for: target.path)
        } catch {
            throw MacBayError.invalidVolume("Unable to inspect volume for \(target.path): \(error.localizedDescription)")
        }

        guard !targetDiskInfo.isInternal else {
            throw MacBayError.externalVolumeRequired("Application target \(target.path) is on an internal volume: \(targetDiskInfo.mountPoint)")
        }

        let targetCheck = volumeManager.eligibilityCheck(for: targetDiskInfo)
        guard targetCheck.isEligible else {
            throw MacBayError.invalidVolume("Target volume \(targetDiskInfo.mountPoint) is not eligible: \(targetCheck.reason ?? "ineligible")")
        }

        let selectedMount = URL(fileURLWithPath: selectedVolumeInfo.mountPoint).standardizedFileURL.path
        let targetMount = URL(fileURLWithPath: targetDiskInfo.mountPoint).standardizedFileURL.path
        guard selectedMount.caseInsensitiveCompare(targetMount) == .orderedSame else {
            throw MacBayError.invalidVolume(
                "Application target \(target.path) is on volume '\(targetDiskInfo.mountPoint)', which does not match the selected volume '\(selectedVolumeInfo.mountPoint)'"
            )
        }

        // 3. 프로세스 / 잠금 / 코드서명 / 호환성 검사
        progress?(.checkingProcesses)
        try processInspector.assertSafeToMove(path: target)
        progress?(.verifyingSignature)
        try verifyCodeSignature(at: target)

        progress?(.checkingCompatibility)
        let assessment = appInspector.assess(bundleURL: target)
        if assessment.grade == .blocked {
            throw MacBayError.compatibilityBlocked(path: target.path, assessment: assessment)
        }
        if assessment.grade == .popupRisk && !dryRun && !force {
            throw MacBayError.forceRequired(path: target.path, assessment: assessment)
        }

        // 4. 목적지 및 manifest 상태 검사
        let destination = MacBayPaths.applicationsRoot(on: volume)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
            .standardizedFileURL

        progress?(.inspectingStorage)
        let sizeBytes = try sizeCalculator.size(of: target)
        let manifest = try manifestStore.load(on: volume)
        guard manifest.version == DockManifest.currentVersion else {
            throw MacBayError.manifestFailed(
                path: MacBayPaths.manifestURL(on: volume).path,
                details: "Unsupported manifest version \(manifest.version) (expected \(DockManifest.currentVersion))"
            )
        }

        let isTargetAtDestination = target.standardizedFileURL.path.caseInsensitiveCompare(destination.path) == .orderedSame
        let existingBySource = manifest.items.first {
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path.caseInsensitiveCompare(source.standardizedFileURL.path) == .orderedSame
        }
        let existingByDest = manifest.items.first {
            URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path.caseInsensitiveCompare(destination.path) == .orderedSame
        }

        let mode: AdoptMode
        if isTargetAtDestination {
            if let existing = existingBySource {
                let recordExternal = URL(fileURLWithPath: existing.externalPath).standardizedFileURL.path
                if recordExternal.caseInsensitiveCompare(destination.path) == .orderedSame {
                    mode = .alreadyAdopted
                } else {
                    throw MacBayError.manifestFailed(
                        path: MacBayPaths.manifestURL(on: volume).path,
                        details: "Manifest conflict: record for '\(source.path)' points to '\(existing.externalPath)', but app is at '\(destination.path)'"
                    )
                }
            } else if let existing = existingByDest {
                throw MacBayError.manifestFailed(
                    path: MacBayPaths.manifestURL(on: volume).path,
                    details: "Manifest conflict: destination '\(destination.path)' is already recorded for '\(existing.sourcePath)'"
                )
            } else {
                mode = .registerOnly
            }
        } else {
            if fileManager.fileExists(atPath: destination.path) {
                throw MacBayError.destinationExists("Destination already exists: \(destination.path). Cannot adopt \(target.path) without overwriting.")
            }
            if let existing = existingBySource {
                throw MacBayError.manifestFailed(
                    path: MacBayPaths.manifestURL(on: volume).path,
                    details: "Manifest conflict: record for '\(source.path)' already exists (pointing to '\(existing.externalPath)')"
                )
            }
            if let existing = existingByDest {
                throw MacBayError.manifestFailed(
                    path: MacBayPaths.manifestURL(on: volume).path,
                    details: "Manifest conflict: destination '\(destination.path)' is already recorded for '\(existing.sourcePath)'"
                )
            }
            mode = .moveAndAdopt
        }

        // 5. 메시지 및 미리보기(--dry-run)
        var messages: [String] = []
        if assessment.grade == .popupRisk {
            messages.append("Warning: Application is flagged with popup risks (\(assessment.reasons.joined(separator: ", ")))")
        }

        switch mode {
        case .alreadyAdopted:
            messages.append("Action: Already adopted in MacBay (no changes needed)")
        case .registerOnly:
            messages.append("Action: Register existing MacBay standard path in manifest (no move required)")
        case .moveAndAdopt:
            messages.append("Action: Move application to MacBay standard path, update symlink, and register in manifest")
        }
        messages.append("Symlink: \(source.path) -> \(target.path)")
        messages.append("Space: estimated internal space freed 0 B (same-volume relocation)")

        if dryRun {
            messages.append("Dry run: no files were changed")
            return MigrationResult(
                operation: "adopt",
                name: source.lastPathComponent,
                sourcePath: target.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: true,
                messages: messages,
                compatibility: assessment
            )
        }

        // 6. 실제 실행 및 원자적 변경 / 복구 처리
        switch mode {
        case .alreadyAdopted:
            messages.append("Application is already adopted by MacBay")
            return MigrationResult(
                operation: "adopt",
                name: source.lastPathComponent,
                sourcePath: target.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: false,
                messages: messages,
                compatibility: assessment
            )

        case .registerOnly:
            let opRecord = AdoptOperationRecord(
                id: UUID().uuidString,
                appName: source.lastPathComponent,
                sourcePath: source.path,
                originalExternalPath: target.path,
                targetExternalPath: destination.path,
                originalLinkTarget: rawLinkDestination,
                volumePath: volume.path,
                phase: .registering,
                timestamp: macBayTimestamp()
            )
            progress?(.savingManifest)
            try operationJournal.save(opRecord, on: volume)

            // 심볼릭 링크가 표준 대상 경로를 가리키지 않는 경우 원자적으로 교체
            let currentTarget = (try? fileManager.destinationOfSymbolicLink(atPath: source.path))
            let linkNeedsUpdate = currentTarget == nil ||
                URL(fileURLWithPath: currentTarget!).standardizedFileURL.path.caseInsensitiveCompare(destination.path) != .orderedSame

            if linkNeedsUpdate {
                progress?(.updatingLink)
                let tempLink = source.deletingLastPathComponent()
                    .appendingPathComponent(".\(source.lastPathComponent).macbay-adopt-\(UUID().uuidString)")
                do {
                    try fileManager.createSymbolicLink(atPath: tempLink.path, withDestinationPath: destination.path)
                    guard Darwin.rename(tempLink.path, source.path) == 0 else {
                        let code = errno
                        throw MacBayError.commandFailed(
                            executable: "rename",
                            status: code,
                            details: String(cString: strerror(code))
                        )
                    }
                } catch {
                    if fileManager.fileExists(atPath: tempLink.path) {
                        try? fileManager.removeItem(at: tempLink)
                    }
                    operationJournal.remove(for: source.lastPathComponent, on: volume)
                    throw error
                }
            }

            let newItem = DockedItem(
                name: source.lastPathComponent,
                sourcePath: source.path,
                externalPath: destination.path,
                sizeBytes: sizeBytes,
                kind: .application,
                dockedAt: macBayTimestamp()
            )

            progress?(.savingManifest)
            do {
                try manifestStore.updating(on: volume) { manifest in
                    manifest.items.removeAll { $0.sourcePath == newItem.sourcePath }
                    manifest.items.append(newItem)
                }
            } catch {
                if linkNeedsUpdate {
                    let restoreLink = source.deletingLastPathComponent()
                        .appendingPathComponent(".\(source.lastPathComponent).macbay-adopt-restore-\(UUID().uuidString)")
                    if (try? fileManager.createSymbolicLink(atPath: restoreLink.path, withDestinationPath: rawLinkDestination)) != nil {
                        _ = Darwin.rename(restoreLink.path, source.path)
                    }
                }
                operationJournal.remove(for: source.lastPathComponent, on: volume)
                throw error
            }

            operationJournal.remove(for: source.lastPathComponent, on: volume)
            messages.append("Adopted \(source.lastPathComponent): registered in manifest")
            return MigrationResult(
                operation: "adopt",
                name: source.lastPathComponent,
                sourcePath: target.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: false,
                messages: messages,
                compatibility: assessment
            )

        case .moveAndAdopt:
            var opRecord = AdoptOperationRecord(
                id: UUID().uuidString,
                appName: source.lastPathComponent,
                sourcePath: source.path,
                originalExternalPath: target.path,
                targetExternalPath: destination.path,
                originalLinkTarget: rawLinkDestination,
                volumePath: volume.path,
                phase: .started,
                timestamp: macBayTimestamp()
            )
            try operationJournal.save(opRecord, on: volume)

            // Step A: 동일 파일시스템 rename 이동
            progress?(.moving)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.moveItem(at: target, to: destination)
            } catch {
                operationJournal.remove(for: source.lastPathComponent, on: volume)
                throw error
            }
            opRecord.phase = .appMoved
            try? operationJournal.save(opRecord, on: volume)

            // 이동 후 서명 재검증
            progress?(.verifyingSignature)
            do {
                try verifyCodeSignature(at: destination)
            } catch {
                try? fileManager.moveItem(at: destination, to: target)
                operationJournal.remove(for: source.lastPathComponent, on: volume)
                throw error
            }

            // Step B: 임시 링크 생성 후 원자적 교체
            progress?(.updatingLink)
            let tempLink = source.deletingLastPathComponent()
                .appendingPathComponent(".\(source.lastPathComponent).macbay-adopt-\(UUID().uuidString)")
            do {
                try fileManager.createSymbolicLink(atPath: tempLink.path, withDestinationPath: destination.path)
                guard Darwin.rename(tempLink.path, source.path) == 0 else {
                    let code = errno
                    throw MacBayError.commandFailed(
                        executable: "rename",
                        status: code,
                        details: String(cString: strerror(code))
                    )
                }
            } catch {
                if fileManager.fileExists(atPath: tempLink.path) {
                    try? fileManager.removeItem(at: tempLink)
                }
                try? fileManager.moveItem(at: destination, to: target)
                operationJournal.remove(for: source.lastPathComponent, on: volume)
                throw error
            }
            opRecord.phase = .linkReplaced
            try? operationJournal.save(opRecord, on: volume)

            // Step C: manifest 저장 (실패 시 원복)
            progress?(.savingManifest)
            let newItem = DockedItem(
                name: source.lastPathComponent,
                sourcePath: source.path,
                externalPath: destination.path,
                sizeBytes: sizeBytes,
                kind: .application,
                dockedAt: macBayTimestamp()
            )

            do {
                try manifestStore.updating(on: volume) { manifest in
                    manifest.items.removeAll { $0.sourcePath == newItem.sourcePath }
                    manifest.items.append(newItem)
                }
            } catch {
                // 심볼릭 링크 원복
                let restoreLink = source.deletingLastPathComponent()
                    .appendingPathComponent(".\(source.lastPathComponent).macbay-adopt-restore-\(UUID().uuidString)")
                if (try? fileManager.createSymbolicLink(atPath: restoreLink.path, withDestinationPath: rawLinkDestination)) != nil {
                    _ = Darwin.rename(restoreLink.path, source.path)
                }
                // 앱 번들 원복
                try? fileManager.moveItem(at: destination, to: target)
                operationJournal.remove(for: source.lastPathComponent, on: volume)
                throw error
            }

            // Step D: 완료 후 작업 기록 정리 및 Dock 갱신
            operationJournal.remove(for: source.lastPathComponent, on: volume)
            progress?(.refreshingDock)
            let dockWarnings = dockRefresher.refresh(for: source)
            messages.append("Adopted \(source.lastPathComponent): moved to MacBay storage, updated symlink, and registered in manifest")
            messages.append(contentsOf: dockWarnings)

            return MigrationResult(
                operation: "adopt",
                name: source.lastPathComponent,
                sourcePath: target.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: false,
                messages: messages,
                compatibility: assessment
            )
        }
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
}
