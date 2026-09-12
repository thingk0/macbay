import Foundation
import MacBayKit

public final class TUIApp: @unchecked Sendable {
    private enum DataRequest: Hashable {
        case status
        case scan
        case doctor
        case preview
        case adoptPlan
        case recovery

        var loadingMessage: String {
            switch self {
            case .status:
                return "Checking storage status…"
            case .scan:
                return "Scanning applications under /Applications…"
            case .doctor:
                return "Diagnosing MacBay links and volume records…"
            case .preview:
                return "Preparing dry-run preview…"
            case .recovery: return "Preparing recovery preview…"
            case .adoptPlan:
                return "Preparing adoption plan…"
            }
        }
    }

    public private(set) var state: TUIState
    public let service: TUIServiceProtocol
    private let controller: TerminalController?
    private let renderer: TerminalRenderer
    private let workerQueue: DispatchQueue
    private let lock = NSRecursiveLock()

    // Guarded by `lock`: at most one request per kind is in flight, the rest wait their turn.
    private var requestsInFlight: Set<DataRequest> = []
    private var queuedRequests: [(request: DataRequest, message: String?, work: () -> Void)] = []

    public private(set) var shouldExit = false
    private var needsRedraw = true

    public init(
        service: TUIServiceProtocol = DefaultTUIService(),
        controller: TerminalController? = nil
    ) {
        self.state = TUIState()
        self.service = service
        self.controller = controller
        self.renderer = TerminalRenderer()
        self.workerQueue = DispatchQueue(label: "macbay.tui.worker", qos: .userInitiated)
    }

    public func run() throws {
        guard let controller else {
            throw MacBayError.unsupportedOperation("TerminalController required for run()")
        }

        try controller.enableRawMode()
        defer {
            controller.restore()
        }

        // Initial load
        loadInitialData()

        var lastTimerTick = Date()

        while !shouldExit {
            var doRender = consumeRedrawRequest()

            if !doRender {
                lock.lock()
                let animating = state.isMutating || state.isLoading
                lock.unlock()

                if animating {
                    let now = Date()
                    if now.timeIntervalSince(lastTimerTick) >= 0.1 {
                        lastTimerTick = now
                        doRender = true
                    }
                }
            }

            if doRender {
                render()
            }

            let key = controller.readKey()
            if key != .none {
                handleKey(key)
                requestRedraw()
            } else {
                updateTimers()
            }
            usleep(15_000)
        }
    }

    /// Marks the frame dirty. Safe to call from any thread.
    public func requestRedraw() {
        lock.lock()
        needsRedraw = true
        lock.unlock()
    }

    /// Takes a pending redraw request, exactly as the render loop does.
    public func consumeRedrawRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard needsRedraw else { return false }
        needsRedraw = false
        return true
    }

    public func render() {
        guard let controller else { return }
        let size = controller.getWindowSize()
        lock.lock()
        let currentState = self.state
        lock.unlock()

        let output = renderer.render(state: currentState, width: size.cols, height: size.rows)
        controller.render(output)
    }

    public func renderString(width: Int = 80, height: Int = 24) -> String {
        lock.lock()
        let currentState = self.state
        lock.unlock()
        return renderer.render(state: currentState, width: width, height: height)
    }

    // MARK: - Data Loading

    public func loadInitialData() {
        loadStatus()
        loadScan()
        loadDoctor()
    }

    public func loadStatus(force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard force || !state.statusLoaded else { return }

        enqueueRequest(.status, force: force) { [weak self] in
            guard let self else { return }
            do {
                let report = try self.service.loadStatus()
                let volumes = try self.service.eligibleVolumes()
                self.lock.lock()
                self.state.cachedStatus = report
                self.state.eligibleVolumesList = volumes
                self.state.statusLoaded = true
                self.lock.unlock()
            } catch {
                self.recordRequestError(error)
            }
        }
    }

    public func loadScan(force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard force || !state.scanLoaded else { return }

        enqueueRequest(.scan, force: force) { [weak self] in
            guard let self else { return }
            do {
                let report = try self.service.loadScan()
                self.lock.lock()
                self.state.cachedScan = report
                self.state.scanLoaded = true
                self.state.moveListIndex = min(self.state.moveListIndex, max(0, self.state.moveCandidates.count - 1))
                self.state.moveListScrollOffset = min(self.state.moveListScrollOffset, self.state.moveListIndex)
                self.state.restoreListIndex = min(self.state.restoreListIndex, max(0, self.state.restoreItems.count - 1))
                self.state.restoreListScrollOffset = min(self.state.restoreListScrollOffset, self.state.restoreListIndex)
                self.lock.unlock()
            } catch {
                self.recordRequestError(error)
            }
        }
    }

    public func loadDoctor(force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard force || !state.doctorLoaded else { return }

        enqueueRequest(.doctor, force: force) { [weak self] in
            guard let self else { return }
            do {
                let report = try self.service.loadDoctor(volumePath: nil)
                self.lock.lock()
                self.state.cachedDoctor = report
                self.state.doctorLoaded = true
                self.lock.unlock()
            } catch {
                self.recordRequestError(error)
            }
        }
    }

    // MARK: - Request Coordination
    //
    // Requests are tracked per kind so that navigating while a load is in flight never drops the
    // data a screen needs. `lock` is recursive, so these helpers are safe to call while holding it.

    private func enqueueRequest(_ request: DataRequest, message: String? = nil, force: Bool = false, work: @escaping () -> Void) {
        if queuedRequests.contains(where: { $0.request == request }) {
            return
        }
        if requestsInFlight.contains(request) {
            // The in-flight run will satisfy normal callers; only an explicit refresh re-runs.
            if force {
                queuedRequests.append((request, message, work))
            }
            return
        }
        if requestsInFlight.isEmpty {
            startRequest(request, message: message, work: work)
        } else {
            queuedRequests.append((request, message, work))
        }
    }

    private func startRequest(_ request: DataRequest, message: String? = nil, work: @escaping () -> Void) {
        requestsInFlight.insert(request)
        state.isLoading = true
        state.loadingMessage = message ?? request.loadingMessage
        state.errorMessage = nil
        needsRedraw = true

        workerQueue.async { [weak self] in
            work()
            self?.completeRequest(request)
        }
    }

    private func completeRequest(_ request: DataRequest) {
        lock.lock()
        requestsInFlight.remove(request)
        state.isLoading = !requestsInFlight.isEmpty
        if !state.isLoading {
            state.loadingMessage = nil
        }
        needsRedraw = true

        if requestsInFlight.isEmpty, !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            startRequest(next.request, message: next.message, work: next.work)
        }
        lock.unlock()
    }

    private func recordRequestError(_ error: Error) {
        lock.lock()
        state.errorMessage = error.localizedDescription
        lock.unlock()
    }

    // MARK: - Key Handling

    public func handleKey(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }

        // Global Ctrl-C / Quit handling
        if key == .ctrlC {
            if state.isMutating {
                state.quitDeferred = true
                return
            }
            shouldExit = true
            return
        }

        if key == .resize {
            return
        }

        let isWindowTooSmall = (controller?.getWindowSize().cols ?? 80) < 80 || (controller?.getWindowSize().rows ?? 24) < 24
        if isWindowTooSmall && !state.isSearching && (key == .char("q") || key == .char("Q")) {
            if state.isMutating {
                state.quitDeferred = true
            } else {
                shouldExit = true
            }
            return
        }

        switch state.currentScreen {
        case .home:
            handleHomeKey(key)
        case .appMoveList:
            handleAppMoveListKey(key)
        case .riskReview(let candidate):
            handleRiskReviewKey(key, candidate: candidate)
        case .volumeSelect(let candidate, let force):
            handleVolumeSelectKey(key, candidate: candidate, force: force)
        case .dryRunPreview(let plan):
            handleDryRunPreviewKey(key, plan: plan)
        case .mutatingProgress:
            handleMutatingProgressKey(key)
        case .operationResult:
            handleOperationResultKey(key)
        case .appRestoreList:
            handleAppRestoreListKey(key)
        case .adoptReview(let plan):
            handleAdoptReviewKey(key, plan: plan)
        case .adoptOutcome:
            handleAdoptOutcomeKey(key)
        case .infoModal:
            handleInfoModalKey(key)
        case .doctorSummary:
            handleDoctorSummaryKey(key)
        case .doctorFindingDetail:
            handleDoctorFindingDetailKey(key)
        case .recovery(let view):
            handleRecoveryKey(key, view: view)
        }
    }

    private func handleHomeKey(_ key: Key) {
        switch key {
        case .up, .char("k"), .char("K"):
            state.homeMenuIndex = max(0, state.homeMenuIndex - 1)
        case .down, .char("j"), .char("J"):
            state.homeMenuIndex = min(3, state.homeMenuIndex + 1)
        case .char("q"), .char("Q"):
            shouldExit = true
        case .char("r"), .char("R"):
            loadStatus(force: true)
        case .enter:
            switch state.homeMenuIndex {
            case 0:
                state.pushScreen(.appMoveList)
                if !state.scanLoaded { loadScan() }
            case 1:
                state.pushScreen(.appRestoreList)
                if !state.statusLoaded { loadStatus() }
                if !state.scanLoaded { loadScan() }
            case 2:
                state.pushScreen(.doctorSummary)
                if !state.doctorLoaded { loadDoctor() }
            case 3:
                shouldExit = true
            default:
                break
            }
        default:
            break
        }
    }

    private func listRowCapacity(for screen: TUIScreen) -> Int {
        let rows = controller?.getWindowSize().rows ?? 24
        return renderer.listVisibleRows(for: screen, terminalHeight: rows)
    }

    private func scrollDetail(by delta: Int) {
        let size = controller?.getWindowSize() ?? (cols: 80, rows: 24)
        guard let metrics = renderer.scrollableDetailMetrics(state: state, width: size.cols, height: size.rows) else {
            return
        }
        let maxOffset = max(0, metrics.total - metrics.viewport)
        state.detailScrollOffset = min(max(0, state.detailScrollOffset + delta), maxOffset)
    }

    private func handleListControls(_ key: Key, restoring: Bool) -> Bool {
        if state.isSearching {
            var query = restoring ? state.restoreSearch : state.moveSearch
            switch key {
            case .enter: state.isSearching = false
            case .escape: query = ""; state.isSearching = false
            case .backspace: if !query.isEmpty { query.removeLast() }
            case .char(let character):
                if query.count < 100 { query.append(character) }
            default: return true
            }
            if restoring { state.restoreSearch = query } else { state.moveSearch = query }
        } else {
            switch key {
            case .char("/"): state.isSearching = true
            case .char("f"), .char("F"):
                if restoring { state.restoreManagedOnly.toggle() } else { state.moveEligibleOnly.toggle() }
            case .char("s"), .char("S"):
                if restoring { state.restoreSortBySize.toggle() } else { state.moveSortByName.toggle() }
            case .char("c"), .char("C"):
                if restoring { state.restoreSearch = ""; state.restoreManagedOnly = false }
                else { state.moveSearch = ""; state.moveEligibleOnly = false }
            default: return false
            }
        }
        if restoring { state.restoreListIndex = 0; state.restoreListScrollOffset = 0 }
        else { state.moveListIndex = 0; state.moveListScrollOffset = 0 }
        return true
    }

    private func handleAppMoveListKey(_ key: Key) {
        if handleListControls(key, restoring: false) { return }
        let candidates = state.moveCandidates
        let listHeight = listRowCapacity(for: .appMoveList)

        switch key {
        case .escape:
            state.popScreen()
        case .char("q"), .char("Q"):
            shouldExit = true
        case .char("r"), .char("R"):
            loadScan(force: true)
        case .up, .char("k"), .char("K"):
            if state.moveListIndex > 0 {
                state.moveListIndex -= 1
                if state.moveListIndex < state.moveListScrollOffset {
                    state.moveListScrollOffset = state.moveListIndex
                }
            }
        case .down, .char("j"), .char("J"):
            if state.moveListIndex < candidates.count - 1 {
                state.moveListIndex += 1
                if state.moveListIndex >= state.moveListScrollOffset + listHeight {
                    state.moveListScrollOffset = state.moveListIndex - listHeight + 1
                }
            }
        case .enter:
            guard candidates.indices.contains(state.moveListIndex) else { return }
            let candidate = candidates[state.moveListIndex]
            if candidate.compatibility?.grade == .blocked {
                state.pushScreen(.infoModal(
                    title: "Application Blocked",
                    message: "This application cannot be relocated to external storage because it requires hypervisor entitlements or kernel extensions.",
                    guidance: candidate.compatibility?.reasons.joined(separator: "; ")
                ))
            } else if candidate.compatibility?.grade == .popupRisk {
                state.riskFocusIndex = 0 // Cancel default
                state.pushScreen(.riskReview(candidate: candidate))
            } else {
                startMoveFlow(candidate: candidate, force: false)
            }
        default:
            break
        }
    }

    private func handleRiskReviewKey(_ key: Key, candidate: AppCandidate) {
        switch key {
        case .escape:
            state.popScreen()
        case .up, .char("k"), .char("K"):
            scrollDetail(by: -1)
        case .down, .char("j"), .char("J"):
            scrollDetail(by: 1)
        case .left, .right, .tab:
            state.riskFocusIndex = (state.riskFocusIndex == 0) ? 1 : 0
        case .enter:
            if state.riskFocusIndex == 0 {
                state.popScreen()
            } else {
                state.popScreen()
                startMoveFlow(candidate: candidate, force: true)
            }
        default:
            break
        }
    }

    private func startMoveFlow(candidate: AppCandidate, force: Bool) {
        // Resolve volume
        if let sessionVol = state.sessionVolumePath {
            startDryRunDock(candidate: candidate, volumePath: sessionVol, force: force)
            return
        }

        if let def = state.cachedStatus?.defaultVolume, let mounted = def.mountedPath ?? (def.path as String?) {
            startDryRunDock(candidate: candidate, volumePath: mounted, force: force)
            return
        } else if let def = try? service.defaultVolume() {
            startDryRunDock(candidate: candidate, volumePath: def.path, force: force)
            return
        }

        var eligible = state.eligibleVolumesList
        if eligible.isEmpty, let queried = try? service.eligibleVolumes() {
            eligible = queried
            state.eligibleVolumesList = queried
        }

        if eligible.count == 1 {
            state.sessionVolumePath = eligible[0].path
            startDryRunDock(candidate: candidate, volumePath: eligible[0].path, force: force)
        } else if eligible.count > 1 {
            state.volumeSelectIndex = 0
            state.pushScreen(.volumeSelect(candidate: candidate, force: force))
        } else {
            state.pushScreen(.infoModal(
                title: "No External Volume",
                message: "No eligible external APFS volume is available to receive this application.",
                guidance: "Connect an external APFS drive and press 'r' to refresh."
            ))
        }
    }

    private func handleVolumeSelectKey(_ key: Key, candidate: AppCandidate, force: Bool) {
        let volumes = state.eligibleVolumesList
        switch key {
        case .escape:
            state.popScreen()
        case .up, .char("k"), .char("K"):
            state.volumeSelectIndex = max(0, state.volumeSelectIndex - 1)
        case .down, .char("j"), .char("J"):
            state.volumeSelectIndex = min(volumes.count - 1, state.volumeSelectIndex + 1)
        case .enter:
            guard volumes.indices.contains(state.volumeSelectIndex) else { return }
            let chosen = volumes[state.volumeSelectIndex]
            state.sessionVolumePath = chosen.path
            state.popScreen()
            startDryRunDock(candidate: candidate, volumePath: chosen.path, force: force)
        default:
            break
        }
    }

    private func startDryRunDock(candidate: AppCandidate, volumePath: String, force: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isMutating else { return }

        let message = "Preparing dry-run preview for \(candidate.name)…"
        enqueueRequest(.preview, message: message) { [weak self] in
            guard let self else { return }
            do {
                let res = try self.service.dock(
                    appName: candidate.name,
                    volumePath: volumePath,
                    dryRun: true,
                    force: force,
                    progress: nil
                )
                self.lock.lock()
                let plan = MigrationPlanPreview(
                    appName: candidate.name,
                    operation: "dock",
                    sourcePath: res.sourcePath,
                    destinationPath: res.destinationPath,
                    sizeBytes: res.sizeBytes,
                    volumePath: volumePath,
                    force: force,
                    messages: res.messages,
                    compatibility: candidate.compatibility
                )
                self.state.confirmFocusIndex = 0 // Cancel is default!
                self.state.pushScreen(.dryRunPreview(plan))
                self.lock.unlock()
            } catch {
                self.lock.lock()
                let msg = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                self.state.pushScreen(.infoModal(
                    title: "Dry-Run Failed",
                    message: msg,
                    guidance: (error as? MacBayError)?.errorDetails
                ))
                self.lock.unlock()
            }
        }
    }

    private func handleDryRunPreviewKey(_ key: Key, plan: MigrationPlanPreview) {
        switch key {
        case .escape:
            state.popScreen()
        case .up, .char("k"), .char("K"):
            scrollDetail(by: -1)
        case .down, .char("j"), .char("J"):
            scrollDetail(by: 1)
        case .left, .right, .tab:
            state.confirmFocusIndex = (state.confirmFocusIndex == 0) ? 1 : 0
        case .enter:
            if state.confirmFocusIndex == 0 {
                // Cancelled!
                state.popScreen()
            } else {
                // Confirmed!
                executeMigration(plan: plan)
            }
        default:
            break
        }
    }

    private func executeMigration(plan: MigrationPlanPreview) {
        guard !state.isMutating else { return }
        state.isMutating = true
        state.currentStepLabel = "Starting migration"
        state.currentStepStarted = Date()
        state.operationStarted = Date()
        state.operationElapsed = 0
        state.completedSteps = []
        state.detailScrollOffset = 0
        state.currentScreen = .mutatingProgress(operation: plan.operation, appName: plan.appName)

        workerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result: MigrationResult
                if plan.operation == "dock" {
                    result = try self.service.dock(
                        appName: plan.appName,
                        volumePath: plan.volumePath,
                        dryRun: false,
                        force: plan.force,
                        progress: { [weak self] step in
                            self?.handleProgress(step)
                        }
                    )
                } else {
                    result = try self.service.undock(
                        appName: plan.appName,
                        volumePath: plan.volumePath,
                        dryRun: false,
                        progress: { [weak self] step in
                            self?.handleProgress(step)
                        }
                    )
                }
                self.handleMigrationSuccess(result: result)
            } catch {
                self.handleMigrationFailure(error: error)
            }
        }
    }

    private func handleProgress(_ step: OperationProgress) {
        lock.lock()
        defer { lock.unlock() }
        defer { needsRedraw = true }

        if case .copyProgress(let sample) = step {
            state.copyProgress = sample
            return
        }
        state.copyProgress = nil
        let label: String
        switch step {
        case .copyProgress: return
        case .selectingVolume: label = "Selecting volume"
        case .validating: label = "Validating application and links"
        case .checkingProcesses: label = "Checking running processes and locks"
        case .verifyingSignature: label = "Verifying code signature"
        case .checkingCompatibility: label = "Checking application compatibility"
        case .inspectingStorage: label = "Checking size, storage and records"
        case .copying: label = "Copying application"
        case .moving: label = "Moving application"
        case .updatingLink: label = "Updating application link"
        case .savingManifest: label = "Saving MacBay records"
        case .refreshingDock: label = "Refreshing Dock"
        }

        if let prevLabel = state.currentStepLabel, let started = state.currentStepStarted {
            let duration = Date().timeIntervalSince(started)
            state.completedSteps.append(CompletedStep(label: prevLabel, duration: duration))
        }
        state.currentStepLabel = label
        state.currentStepStarted = Date()
    }

    private func handleMigrationSuccess(result: MigrationResult) {
        lock.lock()
        state.isMutating = false
        if let prevLabel = state.currentStepLabel, let started = state.currentStepStarted {
            state.completedSteps.append(CompletedStep(label: prevLabel, duration: Date().timeIntervalSince(started)))
            state.currentStepLabel = nil
        }
        if state.quitDeferred {
            shouldExit = true
            lock.unlock()
            return
        }
        state.currentScreen = .operationResult(result: result, error: nil, errorDetails: nil)
        lock.unlock()
        requestRedraw()

        // Reload data
        loadStatus(force: true)
        loadScan(force: true)
    }

    private func handleMigrationFailure(error: Error) {
        lock.lock()
        state.isMutating = false
        if state.quitDeferred {
            shouldExit = true
            lock.unlock()
            return
        }
        let failure = error as? MacBayError
        let msg = failure?.errorDescription ?? error.localizedDescription
        let details = failure?.errorDetails
        state.currentScreen = .operationResult(
            result: nil,
            error: msg,
            errorDetails: (details?.isEmpty ?? true) ? nil : details
        )
        lock.unlock()
        requestRedraw()

        // Reload data
        loadStatus(force: true)
        loadScan(force: true)
    }

    private func handleMutatingProgressKey(_ key: Key) {
        if key == .char("q") || key == .char("Q") || key == .escape {
            state.quitDeferred = true
        }
    }

    private func handleOperationResultKey(_ key: Key) {
        switch key {
        case .enter, .escape:
            state.popScreen()
            if case .dryRunPreview = state.currentScreen {
                state.popScreen()
            }
        default:
            break
        }
    }

    private func handleAppRestoreListKey(_ key: Key) {
        if handleListControls(key, restoring: true) { return }
        let items = state.restoreItems
        let listHeight = listRowCapacity(for: .appRestoreList)

        switch key {
        case .escape:
            state.popScreen()
        case .char("q"), .char("Q"):
            shouldExit = true
        case .char("r"), .char("R"):
            loadStatus(force: true)
            loadScan(force: true)
        case .up, .char("k"), .char("K"):
            if state.restoreListIndex > 0 {
                state.restoreListIndex -= 1
                if state.restoreListIndex < state.restoreListScrollOffset {
                    state.restoreListScrollOffset = state.restoreListIndex
                }
            }
        case .down, .char("j"), .char("J"):
            if state.restoreListIndex < items.count - 1 {
                state.restoreListIndex += 1
                if state.restoreListIndex >= state.restoreListScrollOffset + listHeight {
                    state.restoreListScrollOffset = state.restoreListIndex - listHeight + 1
                }
            }
        case .enter:
            guard items.indices.contains(state.restoreListIndex) else { return }
            let item = items[state.restoreListIndex]
            switch item.status {
            case .managed:
                startDryRunUndock(item: item)
            case .unmanaged:
                startAdoptReview(item: item)
            case .unconfirmed:
                state.pushScreen(.infoModal(
                    title: "Unconfirmed Application",
                    message: "The application target could not be verified at \(item.externalPath).",
                    guidance: "Run 'mb doctor' for diagnosis."
                ))
            case .unresolved(let reason):
                state.pushScreen(.infoModal(
                    title: "Unresolved Symlink",
                    message: "Target missing or broken link: \(reason).",
                    guidance: "Run 'mb doctor' for diagnosis."
                ))
            }
        default:
            break
        }
    }

    private func startDryRunUndock(item: RestoreItem) {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isMutating else { return }

        let message = "Preparing dry-run restore preview for \(item.name)…"
        enqueueRequest(.preview, message: message) { [weak self] in
            guard let self else { return }
            do {
                let res = try self.service.undock(
                    appName: item.name,
                    volumePath: nil,
                    dryRun: true,
                    progress: nil
                )
                self.lock.lock()
                let plan = MigrationPlanPreview(
                    appName: item.name,
                    operation: "undock",
                    sourcePath: res.sourcePath,
                    destinationPath: res.destinationPath,
                    sizeBytes: res.sizeBytes,
                    volumePath: nil,
                    force: false,
                    messages: res.messages
                )
                self.state.confirmFocusIndex = 0 // Cancel is default!
                self.state.pushScreen(.dryRunPreview(plan))
                self.lock.unlock()
            } catch {
                self.lock.lock()
                let msg = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                self.state.pushScreen(.infoModal(
                    title: "Dry-Run Failed",
                    message: msg,
                    guidance: (error as? MacBayError)?.errorDetails
                ))
                self.lock.unlock()
            }
        }
    }

    // MARK: - Adoption Flow
    //
    // Adoption is offered from the restore list because an unmanaged external application cannot
    // be restored until MacBay records it. The volume comes from the selected application's own
    // external path, never from the configured default volume.

    private func startAdoptReview(item: RestoreItem) {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isMutating else { return }

        let message = "Preparing adoption plan for \(item.name)…"
        enqueueRequest(.adoptPlan, message: message) { [weak self] in
            guard let self else { return }

            guard let volumePath = self.service.volumePath(containing: item.externalPath) else {
                self.lock.lock()
                self.state.pushScreen(.infoModal(
                    title: "Volume Not Resolved",
                    message: "MacBay could not determine which volume holds \(item.externalPath).",
                    guidance: "Connect the drive that stores this application, then press 'r' to refresh. Adoption stays disabled until the volume can be verified."
                ))
                self.lock.unlock()
                return
            }

            do {
                let plan = try self.service.planAdopt(appName: item.name, volumePath: volumePath, progress: nil)

                self.lock.lock()
                self.state.adoptReviewFocusIndex = 0 // Cancel is default!
                self.state.adoptRiskAccepted = false
                self.state.detailScrollOffset = 0
                self.lock.unlock()

                if case .alreadyAdopted = plan.status {
                    self.prepareRestorePreviewAfterAdoption(
                        appName: plan.appName,
                        volumePath: volumePath,
                        notice: "Already registered in MacBay on \(volumePath) · no changes were made."
                    )
                    return
                }

                self.lock.lock()
                self.state.pushScreen(.adoptReview(plan: plan))
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.state.pushScreen(.infoModal(
                    title: "Adoption Review Failed",
                    message: self.describe(error: error),
                    guidance: (error as? MacBayError)?.errorDetails
                ))
                self.lock.unlock()
            }
        }
    }

    private func handleAdoptReviewKey(_ key: Key, plan: AdoptPlan) {
        switch key {
        case .escape:
            state.popScreen()
        case .up, .char("k"), .char("K"):
            scrollDetail(by: -1)
        case .down, .char("j"), .char("J"):
            scrollDetail(by: 1)
        case .left, .right, .tab:
            state.adoptReviewFocusIndex = (state.adoptReviewFocusIndex == 0) ? 1 : 0
        case .enter:
            guard state.adoptReviewFocusIndex == 1 else {
                state.popScreen()
                return
            }
            switch renderer.adoptConfirmAction(plan: plan, riskAccepted: state.adoptRiskAccepted) {
            case .unavailable:
                state.popScreen()
            case .acceptRisk:
                state.adoptRiskAccepted = true
                state.detailScrollOffset = 0
            case .adopt:
                executeAdoption(plan: plan)
            }
        default:
            break
        }
    }

    private func executeAdoption(plan: AdoptPlan) {
        guard !state.isMutating else { return }
        guard case .adoptReview = state.currentScreen else { return }

        let requiresForce: Bool
        if case .reviewRequired = plan.status {
            requiresForce = true
        } else {
            requiresForce = false
        }

        state.isMutating = true
        state.currentStepLabel = "Starting adoption"
        state.currentStepStarted = Date()
        state.operationStarted = Date()
        state.operationElapsed = 0
        state.completedSteps = []
        state.detailScrollOffset = 0
        state.currentScreen = .mutatingProgress(operation: "adopt", appName: plan.appName)

        workerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.service.executeAdopt(
                    plan: plan,
                    force: requiresForce,
                    progress: { [weak self] step in
                        self?.handleProgress(step)
                    }
                )
                self.handleAdoptSuccess(result: result, plan: plan)
            } catch {
                self.handleAdoptFailure(error: error, plan: plan)
            }
        }
    }

    private func handleAdoptSuccess(result: AdoptExecutionResult, plan: AdoptPlan) {
        lock.lock()
        state.isMutating = false
        if let prevLabel = state.currentStepLabel, let started = state.currentStepStarted {
            state.completedSteps.append(CompletedStep(label: prevLabel, duration: Date().timeIntervalSince(started)))
            state.currentStepLabel = nil
        }
        if state.quitDeferred {
            shouldExit = true
            lock.unlock()
            return
        }
        lock.unlock()
        requestRedraw()

        loadStatus(force: true)
        loadScan(force: true)

        let volumePath = plan.volumeURL.path
        prepareRestorePreviewAfterAdoption(
            appName: plan.appName,
            volumePath: volumePath,
            notice: "Adoption completed · registered in MacBay records on \(volumePath).",
            adoptedMode: result.mode,
            adoptedSize: result.sizeBytes,
            adoptedLocation: result.sourcePath,
            adoptedDestination: result.destinationPath
        )
    }

    private func handleAdoptFailure(error: Error, plan: AdoptPlan) {
        lock.lock()
        state.isMutating = false
        if let prevLabel = state.currentStepLabel, let started = state.currentStepStarted {
            state.completedSteps.append(CompletedStep(label: prevLabel, duration: Date().timeIntervalSince(started)))
            state.currentStepLabel = nil
        }
        if state.quitDeferred {
            shouldExit = true
            lock.unlock()
            return
        }

        let outcome: AdoptOutcome
        if let adoptError = error as? AdoptExecutionError {
            var rollbackActions: [String] = []
            var rollbackError: String?
            var manualInterventionNeeded: [String] = []
            switch adoptError.rollback {
            case .notRequired:
                break
            case let .succeeded(actions):
                rollbackActions = actions
            case let .failed(reason, intervention):
                rollbackError = reason
                manualInterventionNeeded = intervention
            }
            outcome = AdoptOutcome(
                appName: plan.appName,
                status: .failed(stage: adoptError.stage, message: adoptError.message),
                rollbackActions: rollbackActions,
                rollbackError: rollbackError,
                manualInterventionNeeded: manualInterventionNeeded
            )
        } else {
            let failure = error as? MacBayError
            outcome = AdoptOutcome(
                appName: plan.appName,
                status: .failed(stage: nil, message: failure?.errorDescription ?? error.localizedDescription),
                errorDetails: failure?.errorDetails
            )
        }

        state.currentScreen = .adoptOutcome(outcome)
        lock.unlock()
        requestRedraw()

        loadStatus(force: true)
        loadScan(force: true)
    }

    private func prepareRestorePreviewAfterAdoption(
        appName: String,
        volumePath: String,
        notice: String,
        adoptedMode: AdoptMode? = nil,
        adoptedSize: UInt64? = nil,
        adoptedLocation: String? = nil,
        adoptedDestination: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let message = "Preparing dry-run restore preview for \(appName)…"
        enqueueRequest(.preview, message: message) { [weak self] in
            guard let self else { return }
            do {
                let res = try self.service.undock(
                    appName: appName,
                    volumePath: volumePath,
                    dryRun: true,
                    progress: nil
                )
                self.lock.lock()
                let preview = MigrationPlanPreview(
                    appName: appName,
                    operation: "undock",
                    sourcePath: res.sourcePath,
                    destinationPath: res.destinationPath,
                    sizeBytes: res.sizeBytes,
                    volumePath: volumePath,
                    force: false,
                    messages: res.messages,
                    notice: notice
                )
                self.state.confirmFocusIndex = 0 // Cancel is default!
                // Adoption screens are dropped so cancelling the restore never reopens the review.
                self.state.currentScreen = .dryRunPreview(preview)
                self.lock.unlock()
            } catch {
                self.lock.lock()
                var outcome = AdoptOutcome(
                    appName: appName,
                    status: .completed,
                    mode: adoptedMode,
                    sizeBytes: adoptedSize,
                    currentLocation: adoptedLocation,
                    destinationPath: adoptedDestination,
                    volumePath: volumePath
                )
                outcome.restorePreviewError = self.describe(error: error)
                self.state.currentScreen = .adoptOutcome(outcome)
                self.lock.unlock()
            }
        }
    }

    private func handleAdoptOutcomeKey(_ key: Key) {
        switch key {
        case .enter, .escape:
            state.popScreen()
        case .up, .char("k"), .char("K"):
            scrollDetail(by: -1)
        case .down, .char("j"), .char("J"):
            scrollDetail(by: 1)
        default:
            break
        }
    }

    private func describe(error: Error) -> String {
        (error as? MacBayError)?.errorDescription ?? error.localizedDescription
    }

    private func handleInfoModalKey(_ key: Key) {
        switch key {
        case .enter, .escape:
            state.popScreen()
        default:
            break
        }
    }

    private func handleDoctorSummaryKey(_ key: Key) {
        let findings = state.doctorFindings
        let listHeight = listRowCapacity(for: .doctorSummary)

        switch key {
        case .escape:
            state.popScreen()
        case .char("q"), .char("Q"):
            shouldExit = true
        case .char("r"), .char("R"):
            loadDoctor(force: true)
        case .up, .char("k"), .char("K"):
            if state.doctorListIndex > 0 {
                state.doctorListIndex -= 1
                if state.doctorListIndex < state.doctorListScrollOffset {
                    state.doctorListScrollOffset = state.doctorListIndex
                }
            }
        case .down, .char("j"), .char("J"):
            if state.doctorListIndex < findings.count - 1 {
                state.doctorListIndex += 1
                if state.doctorListIndex >= state.doctorListScrollOffset + listHeight {
                    state.doctorListScrollOffset = state.doctorListIndex - listHeight + 1
                }
            }
        case .enter:
            guard findings.indices.contains(state.doctorListIndex) else { return }
            state.pushScreen(.doctorFindingDetail(findings[state.doctorListIndex]))
        default:
            break
        }
    }

    private func handleDoctorFindingDetailKey(_ key: Key) {
        guard case .doctorFindingDetail(let finding) = state.currentScreen else { return }
        switch key {
        case .escape, .enter: state.popScreen()
        case .up, .char("k"): scrollDetail(by: -1)
        case .down, .char("j"): scrollDetail(by: 1)
        case .char("r"):
            state.popScreen()
            loadDoctor(force: true)
        case .char("p") where finding.code == .localDataDetected:
            prepareRecovery { .comparison(try self.service.compareRepair(finding: finding)) }
        case .char("b") where finding.code == .incompleteOperation:
            prepareRecovery { .rollback(try self.service.previewRollback(finding: finding)) }
        default: break
        }
    }

    private func prepareRecovery(_ work: @escaping () throws -> RecoveryView) {
        guard !state.isMutating, !state.isLoading else { return }
        let origin = state.currentScreen
        enqueueRequest(.recovery) { [weak self] in
            guard let self else { return }
            let view: RecoveryView
            do { view = try work() }
            catch { view = .result(self.describe(error: error)) }
            self.lock.lock()
            defer { self.lock.unlock() }
            // A user can navigate away while a read-only plan is loading.
            guard self.state.currentScreen == origin else { return }
            self.state.recoveryFocus = 0
            self.state.pushScreen(.recovery(view))
        }
    }

    private func handleRecoveryKey(_ key: Key, view: RecoveryView) {
        switch key {
        case .escape: state.popScreen(); state.recoveryFocus = 0
        case .up, .char("k"): scrollDetail(by: -1)
        case .down, .char("j"): scrollDetail(by: 1)
        case .left: state.recoveryFocus = max(0, state.recoveryFocus - 1)
        case .right, .tab:
            let maximum: Int
            if case .comparison = view { maximum = 2 }
            else if case .preview(let plan) = view, case .blocked = plan.status { maximum = 0 }
            else { maximum = 1 }
            state.recoveryFocus = (state.recoveryFocus + 1) % (maximum + 1)
        case .enter:
            guard !state.isLoading else { return }
            if state.recoveryFocus == 0 { state.popScreen(); return }
            switch view {
            case .comparison(let comparison):
                let action: RepairAction = state.recoveryFocus == 1 ? .redock : .keepLocal
                guard comparison.suggestedActions.contains(action), action != .redock || comparison.canRedock else { return }
                prepareRecovery { .preview(try self.service.planRepair(comparison: comparison, action: action)) }
            case .preview(let plan):
                if case .blocked = plan.status { return }
                executeRecovery(view: view, appName: plan.appName)
            case .rollback(let record): executeRecovery(view: view, appName: record.appName)
            case .result:
                state.currentScreen = .doctorSummary
                state.navigationStack = [.home]
                state.detailScrollOffset = 0
                loadDoctor(force: true)
            }
        default: break
        }
    }

    private func executeRecovery(view: RecoveryView, appName: String) {
        guard !state.isMutating, !state.isLoading else { return }
        state.isMutating = true
        state.copyProgress = nil
        state.completedSteps = []
        state.operationStarted = Date()
        state.operationElapsed = 0
        state.currentStepLabel = "Applying reviewed recovery"
        state.currentStepStarted = Date()
        state.currentScreen = .mutatingProgress(operation: "recovery", appName: appName)
        workerQueue.async { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let result: RepairExecutionResult
                switch view {
                case .preview(let plan):
                    let force: Bool
                    if case .reviewRequired = plan.status { force = true } else { force = false }
                    result = try self.service.executeRepair(plan: plan, force: force)
                case .rollback(let record): result = try self.service.executeRollback(record: record)
                default: throw MacBayError.unsupportedOperation("No confirmed recovery plan")
                }
                message = OutputFormatter(useColor: false).formatRepairExecutionResult(result)
            } catch { message = "Recovery failed: \(self.describe(error: error))\nRun diagnosis again before retrying." }
            self.lock.lock()
            self.state.isMutating = false
            self.state.currentStepLabel = nil
            self.state.currentScreen = .recovery(.result(message))
            self.state.navigationStack = [.home, .doctorSummary]
            self.state.detailScrollOffset = 0
            self.state.recoveryFocus = 0
            if self.state.quitDeferred { self.shouldExit = true }
            self.lock.unlock()
            self.requestRedraw()
            self.loadStatus(force: true)
            self.loadScan(force: true)
            self.loadDoctor(force: true)
        }
    }

    private func updateTimers() {
        lock.lock()
        defer { lock.unlock() }

        if state.isMutating, let started = state.operationStarted {
            state.operationElapsed = Date().timeIntervalSince(started)
        }
    }
}
