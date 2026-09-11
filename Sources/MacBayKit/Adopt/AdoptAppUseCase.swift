import Foundation

public protocol AdoptAppUseCaseProtocol: Sendable {
    func plan(
        appName: String,
        on volume: URL,
        progress: ProgressHandler?
    ) throws -> AdoptPlan

    func execute(
        plan: AdoptPlan,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> AdoptExecutionResult
}

public final class AdoptAppUseCase: AdoptAppUseCaseProtocol, @unchecked Sendable {
    private let safetyInspector: any AppSafetyInspector
    private let fileOperations: any BundleFileOperations
    private let manifestRepository: any ManifestRepository
    private let operationJournal: any OperationJournaling
    private let systemRefresher: any SystemEnvironmentRefresher
    private let volumeInspector: any VolumeStorageInspector

    public init(
        safetyInspector: any AppSafetyInspector,
        fileOperations: any BundleFileOperations,
        manifestRepository: any ManifestRepository,
        operationJournal: any OperationJournaling,
        systemRefresher: any SystemEnvironmentRefresher,
        volumeInspector: any VolumeStorageInspector
    ) {
        self.safetyInspector = safetyInspector
        self.fileOperations = fileOperations
        self.manifestRepository = manifestRepository
        self.operationJournal = operationJournal
        self.systemRefresher = systemRefresher
        self.volumeInspector = volumeInspector
    }

    public func plan(
        appName: String,
        on volume: URL,
        progress: ProgressHandler? = nil
    ) throws -> AdoptPlan {
        let startTime = Date()
        var stepRecords: [PreflightStepRecord] = []

        // 1. 경로 및 심볼릭 링크 검증
        progress?(.validating)
        let source = MacBayPaths.applicationURL(named: appName)
        guard source.pathExtension.lowercased() == "app" else {
            throw MacBayError.invalidApplication(source.path)
        }
        guard fileOperations.fileExists(at: source) else {
            throw MacBayError.pathMissing(source.path)
        }

        let resolution = try safetyInspector.inspectSymlink(at: source)
        let target: URL
        switch resolution {
        case let .broken(targetPath, _):
            let destination = MacBayPaths.applicationsRoot(on: volume)
                .appendingPathComponent(source.lastPathComponent, isDirectory: true)
                .standardizedFileURL
            if let incomplete = operationJournal.load(appName: source.lastPathComponent, on: volume),
               incomplete.originalExternalPath == targetPath,
               fileOperations.fileExists(at: destination) {
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
        guard fileOperations.fileExists(at: target) else {
            throw MacBayError.pathMissing(target.path)
        }
        stepRecords.append(PreflightStepRecord(name: "Validating application and links", durationSeconds: Date().timeIntervalSince(startTime)))

        // 2. 볼륨 검증
        let stepVolumeStart = Date()
        progress?(.selectingVolume)
        let selectedVolumeInfo = try volumeInspector.diskInfo(for: volume.path)
        let selectedCheck = volumeInspector.eligibilityCheck(for: selectedVolumeInfo)
        guard selectedCheck.isEligible else {
            if selectedVolumeInfo.isInternal {
                throw MacBayError.externalVolumeRequired("Volume is internal: \(volume.path)")
            } else {
                throw MacBayError.invalidVolume("\(selectedCheck.reason ?? "Volume is not eligible"): \(volume.path)")
            }
        }

        let targetDiskInfo = try volumeInspector.diskInfo(for: target.path)
        guard !targetDiskInfo.isInternal else {
            throw MacBayError.externalVolumeRequired("Application target \(target.path) is on an internal volume: \(targetDiskInfo.mountPoint)")
        }

        let targetCheck = volumeInspector.eligibilityCheck(for: targetDiskInfo)
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
        stepRecords.append(PreflightStepRecord(name: "Checking volume eligibility", durationSeconds: Date().timeIntervalSince(stepVolumeStart)))

        // 3. 프로세스 / 파일 잠금 검사
        let stepProcStart = Date()
        progress?(.checkingProcesses)
        try safetyInspector.assertNoActiveProcessesOrLocks(at: target)
        stepRecords.append(PreflightStepRecord(name: "Checking running processes and locks", durationSeconds: Date().timeIntervalSince(stepProcStart)))

        // 4. 코드서명 무결성 검사
        let stepSigStart = Date()
        progress?(.verifyingSignature)
        try safetyInspector.verifyCodeSignature(at: target)
        stepRecords.append(PreflightStepRecord(name: "Verifying code signature", durationSeconds: Date().timeIntervalSince(stepSigStart)))

        // 5. 호환성 검사
        let stepCompatStart = Date()
        progress?(.checkingCompatibility)
        let assessment = safetyInspector.assessCompatibility(at: target)
        stepRecords.append(PreflightStepRecord(name: "Checking application compatibility", durationSeconds: Date().timeIntervalSince(stepCompatStart)))

        // 6. 목적지 경로 및 매니페스트 상태 확인
        let stepStorageStart = Date()
        progress?(.inspectingStorage)
        let destination = MacBayPaths.applicationsRoot(on: volume)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
            .standardizedFileURL

        let sizeBytes = try fileOperations.calculateSizeBytes(at: target)
        let manifest = try manifestRepository.load(on: volume)
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
            if fileOperations.fileExists(at: destination) {
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
        stepRecords.append(PreflightStepRecord(name: "Checking size, storage and records", durationSeconds: Date().timeIntervalSince(stepStorageStart)))

        // 7. 상태 결정
        let status: AdoptPlanStatus
        if assessment.grade == .blocked {
            status = .blocked(
                reason: assessment.reasons.joined(separator: ", "),
                solution: "Remove virtualization entitlements, kernel/system extensions, or restore corrupted signatures before migrating."
            )
        } else if assessment.grade == .popupRisk {
            status = .reviewRequired(reasons: assessment.reasons, evidence: assessment.evidence)
        } else if mode == .alreadyAdopted {
            status = .alreadyAdopted(details: "Already adopted: application is already located at standard MacBay path and recorded in manifest.")
        } else {
            status = .ready
        }

        return AdoptPlan(
            appName: source.lastPathComponent,
            sourceURL: source,
            targetURL: target,
            destinationURL: destination,
            symlinkURL: source,
            volumeURL: volume,
            mode: mode,
            status: status,
            sizeBytes: sizeBytes,
            compatibility: assessment,
            steps: stepRecords
        )
    }

    public func execute(
        plan: AdoptPlan,
        force: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> AdoptExecutionResult {
        // 1. 정책 검증
        switch plan.status {
        case .blocked:
            throw MacBayError.compatibilityBlocked(path: plan.targetURL.path, assessment: plan.compatibility)
        case .reviewRequired:
            guard force else {
                throw MacBayError.forceRequired(path: plan.targetURL.path, assessment: plan.compatibility)
            }
        case let .alreadyAdopted(details):
            return AdoptExecutionResult(
                outcome: .noChanges(reason: details),
                appName: plan.appName,
                sourcePath: plan.targetURL.path,
                destinationPath: plan.destinationURL.path,
                symlinkPath: plan.symlinkURL.path,
                sizeBytes: plan.sizeBytes,
                mode: .alreadyAdopted,
                rollback: .notRequired
            )
        case let .conflict(reason):
            throw MacBayError.unsupportedOperation("Cannot execute plan due to conflict: \(reason)")
        case .ready:
            break
        }

        // 2. 실행 직전 동적 재검증 (Dynamic Re-verification)
        try safetyInspector.assertNoActiveProcessesOrLocks(at: plan.targetURL)
        if plan.mode == .moveAndAdopt {
            guard !fileOperations.fileExists(at: plan.destinationURL) else {
                throw MacBayError.destinationExists("Destination appeared before execution: \(plan.destinationURL.path)")
            }
        }
        let volumeCheck = try volumeInspector.diskInfo(for: plan.volumeURL.path)
        guard volumeCheck.isWritableVolume else {
            throw MacBayError.invalidVolume("Volume is no longer writable: \(plan.volumeURL.path)")
        }

        // 3. 트랜잭션 실행 및 롤백 추적
        var movedBundle = false
        var symlinkToken: SymlinkSwapRollbackToken? = nil

        let record = AdoptOperationRecord(
            id: UUID().uuidString,
            appName: plan.appName,
            sourcePath: plan.symlinkURL.path,
            originalExternalPath: plan.targetURL.path,
            targetExternalPath: plan.destinationURL.path,
            originalLinkTarget: plan.targetURL.path,
            volumePath: plan.volumeURL.path,
            phase: .started,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        do {
            progress?(.savingManifest)
            try operationJournal.record(operation: record, on: plan.volumeURL)

            if plan.mode == .moveAndAdopt {
                progress?(.moving)
                try fileOperations.moveBundle(from: plan.targetURL, to: plan.destinationURL)
                movedBundle = true
                try operationJournal.record(operation: record.updatingPhase(.appMoved), on: plan.volumeURL)
            }

            progress?(.updatingLink)
            symlinkToken = try fileOperations.atomicReplaceSymlink(at: plan.symlinkURL, pointingTo: plan.destinationURL)
            try operationJournal.record(operation: record.updatingPhase(.linkReplaced), on: plan.volumeURL)

            progress?(.savingManifest)
            try manifestRepository.update(on: plan.volumeURL) { manifest in
                manifest.items.removeAll {
                    URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path.caseInsensitiveCompare(plan.symlinkURL.path) == .orderedSame ||
                    URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path.caseInsensitiveCompare(plan.destinationURL.path) == .orderedSame
                }
                let item = DockedItem(
                    name: plan.appName,
                    sourcePath: plan.symlinkURL.path,
                    externalPath: plan.destinationURL.path,
                    sizeBytes: plan.sizeBytes,
                    kind: .application,
                    dockedAt: ISO8601DateFormatter().string(from: Date())
                )
                manifest.items.append(item)
                manifest.items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            try operationJournal.record(operation: record.updatingPhase(.registering), on: plan.volumeURL)

            progress?(.refreshingDock)
            systemRefresher.refreshLaunchServices(for: plan.destinationURL)
            systemRefresher.restartDock()

            try? operationJournal.remove(appName: plan.appName, on: plan.volumeURL)

            return AdoptExecutionResult(
                outcome: .completed,
                appName: plan.appName,
                sourcePath: plan.targetURL.path,
                destinationPath: plan.destinationURL.path,
                symlinkPath: plan.symlinkURL.path,
                sizeBytes: plan.sizeBytes,
                mode: plan.mode,
                rollback: .notRequired
            )
        } catch {
            var rollbackActions: [String] = []
            var rollbackErrors: [String] = []

            if let token = symlinkToken {
                do {
                    try fileOperations.rollbackSymlink(using: token)
                    rollbackActions.append("Restored original symlink at \(token.symlinkURL.path)")
                } catch {
                    rollbackErrors.append("Failed to restore symlink at \(token.symlinkURL.path): \(error.localizedDescription)")
                }
            }

            if movedBundle {
                do {
                    try fileOperations.rollbackMove(from: plan.destinationURL, to: plan.targetURL)
                    rollbackActions.append("Moved bundle back to \(plan.targetURL.path)")
                } catch {
                    rollbackErrors.append("Failed to move bundle back to \(plan.targetURL.path): \(error.localizedDescription)")
                }
            }

            let rollbackStatus: RollbackStatus
            if rollbackErrors.isEmpty {
                rollbackStatus = .succeeded(actions: rollbackActions)
            } else {
                rollbackStatus = .failed(
                    error: rollbackErrors.joined(separator: "; "),
                    manualInterventionNeeded: [
                        "Inspect application bundle at \(plan.destinationURL.path)",
                        "Inspect application symlink at \(plan.symlinkURL.path)"
                    ]
                )
            }

            throw AdoptExecutionError(
                stage: "execution",
                underlyingError: error,
                rollback: rollbackStatus
            )
        }
    }
}
