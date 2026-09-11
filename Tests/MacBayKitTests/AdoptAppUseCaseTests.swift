import XCTest
@testable import MacBayKit

final class AdoptAppUseCaseTests: XCTestCase {
    private var safetyInspector: MockAppSafetyInspector!
    private var fileOperations: MockBundleFileOperations!
    private var manifestRepository: MockManifestRepository!
    private var operationJournal: MockOperationJournal!
    private var systemRefresher: MockSystemEnvironmentRefresher!
    private var volumeInspector: MockVolumeStorageInspector!
    private var useCase: AdoptAppUseCase!

    private let volumeURL = URL(fileURLWithPath: "/Volumes/ExternalSSD")
    private let sourceURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private let externalTargetURL = URL(fileURLWithPath: "/Volumes/ExternalSSD/Applications/ChatGPT.app")
    private let standardDestURL = URL(fileURLWithPath: "/Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app")

    override func setUp() {
        super.setUp()
        safetyInspector = MockAppSafetyInspector()
        fileOperations = MockBundleFileOperations()
        manifestRepository = MockManifestRepository()
        operationJournal = MockOperationJournal()
        systemRefresher = MockSystemEnvironmentRefresher()
        volumeInspector = MockVolumeStorageInspector()

        useCase = AdoptAppUseCase(
            safetyInspector: safetyInspector,
            fileOperations: fileOperations,
            manifestRepository: manifestRepository,
            operationJournal: operationJournal,
            systemRefresher: systemRefresher,
            volumeInspector: volumeInspector
        )

        // 기본 정상 상태 구성
        fileOperations.existingFiles.insert(sourceURL.path)
        fileOperations.existingFiles.insert(externalTargetURL.path)
        safetyInspector.symlinkResults[sourceURL.path] = .resolved(target: externalTargetURL, hops: 1, usesRelativeDestination: false)
        volumeInspector.diskInfos[volumeURL.path] = VolumeDiskInfo(
            mountPoint: "/Volumes/ExternalSSD",
            isInternal: false,
            filesystemType: "apfs",
            isWritableVolume: true,
            busProtocol: "USB",
            volumeName: "ExternalSSD",
            totalBytes: 1_000_000_000,
            availableBytes: 500_000_000
        )
        volumeInspector.diskInfos[externalTargetURL.path] = volumeInspector.diskInfos[volumeURL.path]
    }

    func testPlanNormalSafeAppReturnsReady() throws {
        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)

        XCTAssertEqual(plan.appName, "ChatGPT.app")
        XCTAssertEqual(plan.status, .ready)
        XCTAssertEqual(plan.mode, .moveAndAdopt)
        XCTAssertEqual(plan.targetURL.path, externalTargetURL.path)
        XCTAssertEqual(plan.destinationURL.path, standardDestURL.path)
    }

    func testExecuteNormalSafeAppCompletesSuccessfully() throws {
        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)
        let result = try useCase.execute(plan: plan, force: false)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(fileOperations.movedItems.count, 1)
        XCTAssertEqual(fileOperations.movedItems.first?.from.path, externalTargetURL.path)
        XCTAssertEqual(fileOperations.movedItems.first?.to.path, standardDestURL.path)
        XCTAssertEqual(fileOperations.replacedSymlinks.count, 1)
        XCTAssertEqual(manifestRepository.manifest.items.count, 1)
        XCTAssertEqual(systemRefresher.refreshedBundles.count, 1)
        XCTAssertTrue(systemRefresher.restartedDock)
    }

    func testPlanReviewRequiredReturnsReviewStatus() throws {
        safetyInspector.compatibility = CompatibilityAssessment(
            grade: .popupRisk,
            reasons: ["DMG relocation prompt code"],
            evidence: ["moveToApplicationsFolder"]
        )

        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)

        if case let .reviewRequired(reasons, evidence) = plan.status {
            XCTAssertEqual(reasons, ["DMG relocation prompt code"])
            XCTAssertEqual(evidence, ["moveToApplicationsFolder"])
        } else {
            XCTFail("Expected .reviewRequired but got \(plan.status)")
        }

        // force: false 실행 시 확인 없이 즉시 예외 발생
        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false)) { error in
            guard case MacBayError.forceRequired = error else {
                XCTFail("Expected forceRequired error but got \(error)")
                return
            }
        }

        // force: true 실행 시 정상 완료
        let result = try useCase.execute(plan: plan, force: true)
        XCTAssertEqual(result.outcome, .completed)
    }

    func testPlanBlockedAppReturnsBlockedStatusAndRefusesExecution() throws {
        safetyInspector.compatibility = CompatibilityAssessment(
            grade: .blocked,
            reasons: ["com.apple.security.virtualization entitlement present"],
            evidence: ["codesign entitlement"]
        )

        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)

        if case let .blocked(reason, _) = plan.status {
            XCTAssertTrue(reason.contains("virtualization"))
        } else {
            XCTFail("Expected .blocked but got \(plan.status)")
        }

        XCTAssertThrowsError(try useCase.execute(plan: plan, force: true)) { error in
            guard case MacBayError.compatibilityBlocked = error else {
                XCTFail("Expected compatibilityBlocked error but got \(error)")
                return
            }
        }
        XCTAssertEqual(fileOperations.movedItems.count, 0)
    }

    func testAlreadyAdoptedReturnsAlreadyAdoptedStatusAndNoChanges() throws {
        // 이미 표준 목적지에 존재하고 매니페스트에도 등록된 경우
        fileOperations.existingFiles.remove(externalTargetURL.path)
        fileOperations.existingFiles.insert(standardDestURL.path)
        safetyInspector.symlinkResults[sourceURL.path] = .resolved(target: standardDestURL, hops: 1, usesRelativeDestination: false)
        volumeInspector.diskInfos[standardDestURL.path] = volumeInspector.diskInfos[volumeURL.path]

        manifestRepository.manifest = DockManifest(items: [
            DockedItem(
                name: "ChatGPT.app",
                sourcePath: sourceURL.path,
                externalPath: standardDestURL.path,
                sizeBytes: 120_000_000,
                kind: .application,
                dockedAt: "2026-09-11T00:00:00Z"
            )
        ])

        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)
        XCTAssertEqual(plan.mode, .alreadyAdopted)
        if case .alreadyAdopted = plan.status {
            // expected
        } else {
            XCTFail("Expected .alreadyAdopted status but got \(plan.status)")
        }

        let result = try useCase.execute(plan: plan, force: false)
        guard case let .noChanges(reason) = result.outcome else {
            XCTFail("Expected .noChanges outcome but got \(result.outcome)")
            return
        }
        XCTAssertTrue(reason.contains("Already adopted"))
        XCTAssertEqual(fileOperations.movedItems.count, 0)
    }

    func testDynamicReverificationStopsIfProcessLaunchedBeforeExecute() throws {
        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)

        // 검사 완료 후 사용자가 확인을 누르는 사이 프로세스가 실행됨을 모사
        let lock = ProcessLock(process: "ChatGPT", pid: 12345, user: "user", fileDescriptor: "txt", path: externalTargetURL.path)
        safetyInspector.failOnAssertProcess = MacBayError.activeProcesses(path: externalTargetURL.path, locks: [lock])

        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false)) { error in
            guard case MacBayError.activeProcesses = error else {
                XCTFail("Expected activeProcesses error but got \(error)")
                return
            }
        }

        // 파일이나 링크는 전혀 변경되지 않음
        XCTAssertEqual(fileOperations.movedItems.count, 0)
        XCTAssertEqual(fileOperations.replacedSymlinks.count, 0)
    }

    func testManifestFailureInjectsRollbackOfBundleAndSymlink() throws {
        let plan = try useCase.plan(appName: "ChatGPT.app", on: volumeURL)

        // 매니페스트 갱신 시 디스크 쓰기 오류 주입
        manifestRepository.failOnUpdate = MacBayError.manifestFailed(path: "/Volumes/ExternalSSD/MacBay/manifest.json", details: "Mock Disk I/O Error")

        XCTAssertThrowsError(try useCase.execute(plan: plan, force: false)) { error in
            guard let adoptError = error as? AdoptExecutionError else {
                XCTFail("Expected AdoptExecutionError but got \(error)")
                return
            }
            XCTAssertEqual(adoptError.stage, "execution")
            if case let .succeeded(actions) = adoptError.rollback {
                XCTAssertEqual(actions.count, 2)
                XCTAssertTrue(actions[0].contains("Restored original symlink"))
                XCTAssertTrue(actions[1].contains("Moved bundle back"))
            } else {
                XCTFail("Expected rollback .succeeded but got \(adoptError.rollback)")
            }
        }

        // 롤백 확인: 이동 취소 호출되었고 심볼릭 링크 롤백 호출됨
        XCTAssertEqual(fileOperations.rollbackMoveCalls.count, 1)
        XCTAssertEqual(fileOperations.rollbackSymlinkCalls.count, 1)
    }
}

// MARK: - Mocks

final class MockAppSafetyInspector: AppSafetyInspector, @unchecked Sendable {
    var symlinkResults: [String: SymlinkResolution] = [:]
    var failOnAssertProcess: Error?
    var failOnCodeSignature: Error?
    var compatibility: CompatibilityAssessment = CompatibilityAssessment(grade: .safe, reasons: [], evidence: [])

    func inspectSymlink(at source: URL) throws -> SymlinkResolution {
        if let res = symlinkResults[source.path] { return res }
        return .resolved(target: source, hops: 1, usesRelativeDestination: false)
    }

    func assertNoActiveProcessesOrLocks(at target: URL) throws {
        if let error = failOnAssertProcess { throw error }
    }

    func verifyCodeSignature(at target: URL) throws {
        if let error = failOnCodeSignature { throw error }
    }

    func assessCompatibility(at target: URL) -> CompatibilityAssessment {
        compatibility
    }
}

final class MockBundleFileOperations: BundleFileOperations, @unchecked Sendable {
    var existingFiles: Set<String> = []
    var movedItems: [(from: URL, to: URL)] = []
    var replacedSymlinks: [(symlink: URL, target: URL)] = []
    var rollbackMoveCalls: [(from: URL, to: URL)] = []
    var rollbackSymlinkCalls: [SymlinkSwapRollbackToken] = []

    func fileExists(at url: URL) -> Bool {
        existingFiles.contains(url.path)
    }

    func calculateSizeBytes(at url: URL) throws -> UInt64 {
        120_000_000
    }

    func moveBundle(from source: URL, to destination: URL) throws {
        movedItems.append((from: source, to: destination))
        existingFiles.remove(source.path)
        existingFiles.insert(destination.path)
    }

    func atomicReplaceSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws -> SymlinkSwapRollbackToken {
        replacedSymlinks.append((symlink: symlinkURL, target: targetURL))
        return SymlinkSwapRollbackToken(symlinkURL: symlinkURL, originalTarget: "/original/target/path")
    }

    func rollbackSymlink(using token: SymlinkSwapRollbackToken) throws {
        rollbackSymlinkCalls.append(token)
    }

    func rollbackMove(from destination: URL, to source: URL) throws {
        rollbackMoveCalls.append((from: destination, to: source))
        existingFiles.remove(destination.path)
        existingFiles.insert(source.path)
    }
}

final class MockManifestRepository: ManifestRepository, @unchecked Sendable {
    var manifest: DockManifest = DockManifest(items: [])
    var failOnUpdate: Error?

    func load(on volume: URL) throws -> DockManifest {
        manifest
    }

    func update(on volume: URL, mutate: (inout DockManifest) throws -> Void) throws {
        if let error = failOnUpdate {
            throw error
        }
        try mutate(&manifest)
    }
}

final class MockOperationJournal: OperationJournaling, @unchecked Sendable {
    var recordedOperations: [String: AdoptOperationRecord] = [:]

    func record(operation: AdoptOperationRecord, on volume: URL) throws {
        recordedOperations[operation.appName] = operation
    }

    func remove(appName: String, on volume: URL) throws {
        recordedOperations.removeValue(forKey: appName)
    }

    func load(appName: String, on volume: URL) -> AdoptOperationRecord? {
        recordedOperations[appName]
    }
}

final class MockSystemEnvironmentRefresher: SystemEnvironmentRefresher, @unchecked Sendable {
    var refreshedBundles: [URL] = []
    var restartedDock = false

    func refreshLaunchServices(for bundleURL: URL) {
        refreshedBundles.append(bundleURL)
    }

    func restartDock() {
        restartedDock = true
    }
}

final class MockVolumeStorageInspector: VolumeStorageInspector, @unchecked Sendable {
    var diskInfos: [String: VolumeDiskInfo] = [:]

    func diskInfo(for path: String) throws -> VolumeDiskInfo {
        if let info = diskInfos[path] { return info }
        // fallback match prefix
        for (key, val) in diskInfos.sorted(by: { $0.key.count > $1.key.count }) {
            if path.hasPrefix(key) { return val }
        }
        throw MacBayError.invalidVolume("No mock disk info for \(path)")
    }

    func eligibilityCheck(for info: VolumeDiskInfo) -> (isEligible: Bool, reason: String?) {
        if info.isInternal { return (false, "Internal volume") }
        if !info.isWritableVolume { return (false, "Read-only volume") }
        if info.filesystemType.lowercased() != "apfs" { return (false, "Not APFS") }
        return (true, nil)
    }
}
