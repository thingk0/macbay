import Combine
import Foundation
import MacBayKit

public struct GUIAlert: Identifiable {
    public let id = UUID()
    public let message: String
}

@MainActor
public final class GUIStore: ObservableObject {
    @Published public var showsSidebar = true
    @Published public var showsSettings = false
    @Published public var showsSetup = false
    @Published public var showsReleaseCheck = false
    @Published public private(set) var isCheckingRelease = false
    @Published public private(set) var releaseInfo: GUIReleaseInfo?
    @Published public private(set) var releaseError: String?
    @Published public private(set) var setupReport: GUISetupReport?
    @Published public private(set) var setupError: String?
    @Published public private(set) var isCheckingSetup = false
    @Published public private(set) var isSavingSetup = false
    @Published public private(set) var navigationHistory = GUISectionHistory()
    @Published public var section: GUISection = .overview {
        didSet {
            if section != oldValue {
                navigationHistory.visit(section)
                invalidatePreview()
            }
        }
    }
    @Published public var appLocation: GUIAppLocation = .onMac {
        didSet { if appLocation != oldValue { selectedApplicationID = nil } }
    }
    @Published public var search = ""
    @Published public var searchFocusRequest = 0
    @Published public var selectedApplicationID: String? {
        didSet { if selectedApplicationID != oldValue { invalidatePreview() } }
    }
    @Published public var selectedVolumePath: String? {
        didSet { if selectedVolumePath != oldValue { invalidatePreview() } }
    }
    @Published public var selectedCacheIDs = Set<String>() {
        didSet { if selectedCacheIDs != oldValue { invalidatePreview() } }
    }
    @Published public var preview: GUIPreview?
    @Published public var alert: GUIAlert?
    @Published public private(set) var updateRecords: [UpdateWorkflowRecord] = []
    @Published public private(set) var updateError: String?
    @Published public private(set) var recoverySnapshot: GUIRecoverySnapshot?
    @Published public private(set) var recoveryError: String?
    @Published public private(set) var actionPreview: GUIActionPreview?
    @Published public private(set) var actionResult: GUIActionResult?
    @Published public private(set) var actionProgress = GUIActionProgress("Preparing…")
    @Published public private(set) var isExecutingAction = false
    @Published public private(set) var isFinalizingAction = false
    @Published public private(set) var statusReport: StatusReport?
    @Published public private(set) var scanReport: ScanReport?
    @Published public private(set) var doctorReport: DoctorReport?
    @Published public private(set) var historyEntries: [HistoryEntry] = []
    @Published public private(set) var cacheItems: [PurgeItem] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isScanning = false
    @Published public private(set) var isScanningCaches = false
    @Published public private(set) var isPreparingPreview = false
    @Published public private(set) var statusError: String?
    @Published public private(set) var doctorError: String?
    @Published public private(set) var hasScanned = false
    @Published public private(set) var hasScannedCaches = false
    public let isDemo: Bool
    public var onActionCompleted: ((GUIActionResult) -> Void)?
    private let service: any GUIServiceProtocol
    private let releaseChecker: any GUIReleaseChecking
    private let volumeMonitor = VolumeChangeMonitor()
    private var volumeSubscription: UUID?
    private var previewGeneration = 0
    private var started = false
    private var refreshRequested = false
    private var isRefreshingStorage = false
    private var storageGeneration = 0
    private var executionID: UUID?
    private var setupGeneration = 0
    private var setupAfterSettings = false
    private var releaseAfterSettings = false

    public init(service: any GUIServiceProtocol, isDemo: Bool = false, monitorVolumes: Bool = true,
                releaseChecker: any GUIReleaseChecking = GitHubGUIReleaseChecker()) {
        self.service = service
        self.releaseChecker = releaseChecker
        self.isDemo = isDemo
        if monitorVolumes && !isDemo {
            volumeSubscription = volumeMonitor.subscribe { [weak self] in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }
    }
    deinit {
        if let volumeSubscription { volumeMonitor.unsubscribe(volumeSubscription) }
    }

    public var applications: [GUIApplication] { GUIApplication.rows(scan: scanReport, status: statusReport) }
    public var visibleApplications: [GUIApplication] {
        applications.filter { app in
            (appLocation == .all || (appLocation == .external ? app.isExternal : !app.isExternal))
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
        }
    }
    public var selectedApplication: GUIApplication? { applications.first { $0.id == selectedApplicationID } }
    public var selectedVolume: StorageVolume? { statusReport?.externalVolumes.first { $0.path == selectedVolumePath } }
    public var selectedCaches: [PurgeItem] { cacheItems.filter { selectedCacheIDs.contains($0.id) && !$0.isRunning } }
    public var canPreviewApplication: Bool {
        guard let app = selectedApplication, app.canPreview, canPrepareWorkflow else { return false }
        return app.isRestore || selectedVolume != nil
    }
    public var attentionCount: Int? {
        guard let doctorReport else { return nil }
        return doctorReport.summary.needsAttention + doctorReport.summary.unableToVerify
    }
    public var warnings: [String] {
        var seen = Set<String>()
        return ((statusReport?.warnings ?? []) + (scanReport?.warnings ?? []) + (doctorReport?.warnings ?? []))
            .filter { seen.insert($0).inserted }
    }
    public var moveCandidateBytes: UInt64 {
        applications.filter { !$0.isExternal && $0.canPreview }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }
    public var updateApplications: [GUIApplication] {
        applications.filter { app in app.state == .external && !updateRecords.contains { $0.sourcePath == app.path } }
    }
    public var canPrepareWorkflow: Bool { !isRefreshing && !isPreparingPreview && !isExecutingAction && !isFinalizingAction && actionResult == nil }
    public var showsActionSheet: Bool { actionPreview != nil || actionResult != nil || isExecutingAction }

    public func goBack() {
        guard !isExecutingAction, !isSavingSetup, !showsActionSheet,
              let previous = navigationHistory.goBack() else { return }
        section = previous
    }

    public func goForward() {
        guard !isExecutingAction, !isSavingSetup, !showsActionSheet,
              let next = navigationHistory.goForward() else { return }
        section = next
    }

    public func start() async {
        guard !started else { return }
        started = true
        await refresh()
        await scanApplications()
    }

    public func refresh() async {
        if isExecutingAction { refreshRequested = true; return }
        if isRefreshing { refreshRequested = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            storageGeneration += 1
            invalidatePreview()
            do {
                let status = try await service.status()
                applyStorageStatus(status)
            } catch {
                statusReport = nil
                selectedVolumePath = nil
                statusError = error.localizedDescription
            }
            do {
                doctorReport = try await service.doctor()
                doctorError = nil
            } catch {
                doctorReport = nil
                doctorError = error.localizedDescription
            }
            historyEntries = await service.history()
            do {
                updateRecords = try await service.updates()
                updateError = nil
            } catch {
                updateRecords = []
                updateError = error.localizedDescription
            }
            do {
                recoverySnapshot = try await service.recovery()
                recoveryError = nil
            } catch {
                recoverySnapshot = nil
                recoveryError = error.localizedDescription
            }
        } while refreshRequested && !Task.isCancelled
    }

    /// Menu-bar polling reads capacity only, without rescanning apps or discarding a reviewed preview.
    public func refreshStorage() async {
        guard !isRefreshingStorage, !isRefreshing, !isExecutingAction, !isFinalizingAction, !isPreparingPreview else { return }
        isRefreshingStorage = true
        storageGeneration += 1
        let generation = storageGeneration
        defer { isRefreshingStorage = false }
        do {
            let status = try await service.status()
            guard generation == storageGeneration, !Task.isCancelled, !isExecutingAction else { return }
            applyStorageStatus(status)
        } catch {
            guard generation == storageGeneration, !Task.isCancelled, !isExecutingAction else { return }
            statusReport = nil
            selectedVolumePath = nil
            statusError = error.localizedDescription
        }
    }

    private func applyStorageStatus(_ status: StatusReport) {
        statusReport = status
        statusError = nil
        let paths = Set(status.externalVolumes.map(\.path))
        if selectedVolumePath.map({ paths.contains($0) }) != true {
            if let configured = status.defaultVolume?.mountedPath, paths.contains(configured) {
                selectedVolumePath = configured
            } else if status.defaultVolume != nil {
                selectedVolumePath = nil
            } else if status.externalVolumes.count == 1 {
                selectedVolumePath = status.externalVolumes[0].path
            } else {
                selectedVolumePath = nil
            }
        }
    }

    public func scanApplications() async {
        guard !isScanning, !isExecutingAction else { return }
        invalidatePreview()
        isScanning = true
        defer { isScanning = false }
        scanReport = await service.scan()
        hasScanned = true
        if !applications.contains(where: { $0.id == selectedApplicationID }) { selectedApplicationID = nil }
    }

    public func scanCaches() async {
        guard !isScanningCaches, !isExecutingAction else { return }
        invalidatePreview()
        isScanningCaches = true
        defer { isScanningCaches = false }
        cacheItems = await service.caches()
        selectedCacheIDs.formIntersection(Set(cacheItems.filter { !$0.isRunning }.map(\.id)))
        hasScannedCaches = true
    }

    public func previewApplication() async {
        guard canPreviewApplication, let app = selectedApplication else { return }
        let service = self.service
        let path = selectedVolumePath
        await prepareWorkflow { try await service.previewApplication(app, volumePath: path) }
    }
    public func previewCleanup() async {
        guard canPrepareWorkflow, !isScanningCaches else { return }
        let items = selectedCaches
        guard !items.isEmpty else { return }
        let service = self.service
        await prepareWorkflow { try await service.previewCaches(items) }
    }
    public func previewXcode() async {
        guard !isExecutingAction else { return }
        guard let path = selectedVolume?.path else { return }
        let service = self.service
        await prepare { try await service.previewXcode(volumePath: path) }
    }
    public func dismissPreview() { invalidatePreview() }

    public func requestSetup() {
        guard !isExecutingAction else { return }
        if showsSettings { setupAfterSettings = true; showsSettings = false }
        else { showsSetup = true }
    }
    public func settingsDismissed() {
        if setupAfterSettings { setupAfterSettings = false; showsSetup = true }
        if releaseAfterSettings { releaseAfterSettings = false; Task { await checkForAppUpdates() } }
    }
    public func requestReleaseCheck() {
        guard !isExecutingAction, !showsSetup, !showsActionSheet else { return }
        if showsSettings { releaseAfterSettings = true; showsSettings = false }
        else { Task { await checkForAppUpdates() } }
    }
    public func checkForAppUpdates() async {
        guard !isCheckingRelease else { return }
        showsReleaseCheck = true
        isCheckingRelease = true
        releaseInfo = nil
        releaseError = nil
        defer { isCheckingRelease = false }
        do {
            if isDemo {
                releaseInfo = GUIReleaseInfo(status: .upToDate, installedVersion: GUIAppInfo.version, latestVersion: GUIAppInfo.version)
            } else { releaseInfo = try await releaseChecker.check(installedVersion: GUIAppInfo.version) }
        } catch { releaseError = error.localizedDescription }
    }
    public func checkSetup() async {
        setupGeneration += 1
        let generation = setupGeneration
        let path = selectedVolumePath
        setupReport = nil
        setupError = nil
        isCheckingSetup = true
        defer { if generation == setupGeneration { isCheckingSetup = false } }
        do {
            let report = try await service.setupChecks(volumePath: path)
            guard generation == setupGeneration, path == selectedVolumePath else {
                await service.discardAction(report.id)
                return
            }
            setupReport = report
        } catch {
            if generation == setupGeneration { setupError = error.localizedDescription }
        }
    }
    public func finishSetup(saveDefault: Bool) async -> Bool {
        guard !isSavingSetup, !isCheckingSetup, let report = setupReport,
              report.volumePath == selectedVolumePath, !saveDefault || report.canSaveDefault else { return false }
        isSavingSetup = true
        defer { isSavingSetup = false }
        do {
            if saveDefault { try await service.saveSetup(report.id) }
            dismissSetup()
            await refresh()
            return true
        } catch {
            setupError = error.localizedDescription
            return false
        }
    }
    public func dismissSetup() {
        setupGeneration += 1
        if let report = setupReport {
            let service = self.service
            Task { await service.discardAction(report.id) }
        }
        setupReport = nil
        isCheckingSetup = false
        showsSetup = false
    }

    public func previewUpdate(_ request: GUIUpdateRequest) async {
        guard canPrepareWorkflow, updateError == nil else { return }
        let service = self.service
        await prepareWorkflow { try await service.previewUpdate(request) }
    }

    public func previewRecovery(_ item: GUIRecoveryItem) async {
        guard canPrepareWorkflow, item.capability.actionTitle != nil else { return }
        let service = self.service
        await prepareWorkflow { try await service.previewRecovery(item) }
    }

    private func prepareWorkflow(_ work: @Sendable () async throws -> GUIActionPreview) async {
        invalidatePreview()
        let generation = previewGeneration
        isPreparingPreview = true
        defer { if generation == previewGeneration { isPreparingPreview = false } }
        do {
            let result = try await work()
            guard generation == previewGeneration, !Task.isCancelled else {
                await service.discardAction(result.id)
                return
            }
            actionPreview = result
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            alert = GUIAlert(message: error.localizedDescription)
        }
    }

    public func dismissAction() {
        guard !isExecutingAction, !isFinalizingAction else { return }
        invalidatePreview()
        actionResult = nil
    }

    public func confirmAction(_ confirmation: GUIActionConfirmation) async {
        guard let reviewed = actionPreview, reviewed.accepts(confirmation), canPrepareWorkflow else { return }
        isExecutingAction = true
        let runID = UUID()
        executionID = runID
        actionProgress = GUIActionProgress("Rechecking the preview…")
        do {
            actionResult = try await service.executeAction(confirmation) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard self?.executionID == runID else { return }
                    self?.actionProgress = event
                }
            }
        } catch {
            actionResult = GUIActionResult(succeeded: false, title: "Action stopped",
                messages: [error.localizedDescription,
                           "Review the refreshed workflow and Diagnostics. A new preview is required before retrying."], canOpenRecovery: true)
        }
        executionID = nil
        let completedResult = actionResult
        isFinalizingAction = true
        isExecutingAction = false
        actionPreview = nil
        await refresh()
        await scanApplications()
        if hasScannedCaches { await scanCaches() }
        isFinalizingAction = false
        if let completedResult { onActionCompleted?(completedResult) }
    }

    private func invalidatePreview() {
        previewGeneration += 1
        preview = nil
        isPreparingPreview = false
        if !isExecutingAction, let action = actionPreview {
            actionPreview = nil
            let service = self.service
            Task { await service.discardAction(action.id) }
        }
    }
    private func prepare(_ work: @Sendable () async throws -> GUIPreview) async {
        invalidatePreview()
        let generation = previewGeneration
        isPreparingPreview = true
        defer { if generation == previewGeneration { isPreparingPreview = false } }
        do {
            let result = try await work()
            guard generation == previewGeneration, !Task.isCancelled else { return }
            preview = result
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            alert = GUIAlert(message: error.localizedDescription)
        }
    }
}
