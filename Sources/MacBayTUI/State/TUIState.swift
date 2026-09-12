import Foundation
import MacBayKit

public enum TUIScreen: Equatable {
    case home
    case appMoveList
    case riskReview(candidate: AppCandidate)
    case volumeSelect(candidate: AppCandidate, force: Bool)
    case dryRunPreview(MigrationPlanPreview)
    case mutatingProgress(operation: String, appName: String)
    case operationResult(result: MigrationResult?, error: String?, errorDetails: String?)
    case appRestoreList
    case adoptReview(plan: AdoptPlan)
    case adoptOutcome(AdoptOutcome)
    case infoModal(title: String, message: String, guidance: String?)
    case recovery(RecoveryView)
    case doctorSummary
    case doctorFindingDetail(DoctorFinding)
}

public struct TUIState: Equatable {
    public var currentScreen: TUIScreen = .home
    public var navigationStack: [TUIScreen] = []

    public var sessionVolumePath: String?
    public var eligibleVolumesList: [StorageVolume] = []

    public var cachedStatus: StatusReport?
    public var cachedScan: ScanReport?
    public var cachedDoctor: DoctorReport?

    public var statusLoaded = false
    public var scanLoaded = false
    public var doctorLoaded = false

    public var isLoading = false
    public var loadingMessage: String?
    public var isMutating = false
    public var quitDeferred = false
    public var errorMessage: String?

    // In-progress mutating operation tracking
    public var copyProgress: CopyProgress?
    public var currentStepLabel: String?
    public var currentStepStarted: Date?
    public var completedSteps: [CompletedStep] = []
    public var operationStarted: Date?
    public var operationElapsed: TimeInterval = 0

    // List indices and scrolling
    public var moveSearch = ""
    public var restoreSearch = ""
    public var isSearching = false
    public var moveEligibleOnly = false
    public var restoreManagedOnly = false
    public var moveSortByName = false
    public var restoreSortBySize = false

    public var homeMenuIndex = 0
    public var moveListIndex = 0
    public var moveListScrollOffset = 0
    public var restoreListIndex = 0
    public var restoreListScrollOffset = 0
    public var doctorListIndex = 0
    public var doctorListScrollOffset = 0
    public var volumeSelectIndex = 0

    // Scroll offset for screens whose body scrolls while the footer stays fixed
    public var detailScrollOffset = 0

    // Focus for dual-button modals (0 = Cancel, 1 = Confirm/Accept)
    public var confirmFocusIndex = 0
    public var riskFocusIndex = 0
    public var adoptReviewFocusIndex = 0
    public var adoptRiskAccepted = false
    public var recoveryFocus = 0

    public init() {}

    public var moveCandidates: [AppCandidate] {
        guard let scan = cachedScan else { return [] }
        return scan.candidates
            .filter { $0.kind == .application }
            .filter { moveSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(moveSearch) }
            .filter { !moveEligibleOnly || $0.compatibility?.grade == .safe }
            .sorted {
                if !moveSortByName, $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public var restoreItems: [RestoreItem] {
        var items: [RestoreItem] = []
        var seenSourcePaths = Set<String>()

        if let status = cachedStatus {
            for item in status.dockedItems where item.kind == .application {
                items.append(RestoreItem(
                    name: item.name,
                    sourcePath: item.sourcePath,
                    externalPath: item.externalPath,
                    sizeBytes: item.sizeBytes,
                    status: .managed
                ))
                seenSourcePaths.insert(item.sourcePath.lowercased())
            }
        }

        if let scan = cachedScan {
            for ext in scan.externalApplications {
                if !seenSourcePaths.contains(ext.sourcePath.lowercased()) {
                    let status: RestoreStatus
                    switch ext.managementStatus {
                    case .macBay: status = .managed
                    case .unmanaged: status = .unmanaged
                    case .unconfirmed: status = .unconfirmed
                    }
                    items.append(RestoreItem(
                        name: ext.name,
                        sourcePath: ext.sourcePath,
                        externalPath: ext.destinationPath,
                        sizeBytes: ext.sizeBytes,
                        status: status
                    ))
                    seenSourcePaths.insert(ext.sourcePath.lowercased())
                }
            }
            for unres in scan.unresolvedApplicationLinks {
                if !seenSourcePaths.contains(unres.sourcePath.lowercased()) {
                    items.append(RestoreItem(
                        name: unres.name,
                        sourcePath: unres.sourcePath,
                        externalPath: unres.destinationPath,
                        sizeBytes: nil,
                        status: .unresolved(reason: unres.reason)
                    ))
                    seenSourcePaths.insert(unres.sourcePath.lowercased())
                }
            }
        }
        return items.filter { restoreSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(restoreSearch) }
            .filter { !restoreManagedOnly || $0.status == .managed }
            .sorted {
                if restoreSortBySize, $0.sizeBytes != $1.sizeBytes { return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public var doctorFindings: [DoctorFinding] {
        cachedDoctor?.findings ?? []
    }

    public mutating func pushScreen(_ newScreen: TUIScreen) {
        navigationStack.append(currentScreen)
        currentScreen = newScreen
        detailScrollOffset = 0
    }

    @discardableResult
    public mutating func popScreen() -> Bool {
        guard let prev = navigationStack.popLast() else {
            return false
        }
        currentScreen = prev
        detailScrollOffset = 0
        return true
    }

    public mutating func resetToHome() {
        navigationStack.removeAll()
        currentScreen = .home
    }
}
