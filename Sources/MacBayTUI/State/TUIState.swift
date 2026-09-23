import Foundation
import MacBayKit

public enum TUIScreen: Equatable {
    case home
    case appMoveList
    case appFilter(restoring: Bool)
    case explorer
    case explorerDetail(entry: ExplorerEntry)
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

/// Status choices for the move-application list filter.
public enum MoveStatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case safe
    case review
    case blocked
    case unknown

    public var label: String {
        switch self {
        case .all: return "All"
        case .safe: return "Safe"
        case .review: return "Review"
        case .blocked: return "Blocked"
        case .unknown: return "Unknown"
        }
    }

    fileprivate func matches(_ candidate: AppCandidate) -> Bool {
        switch self {
        case .all: return true
        case .safe: return candidate.compatibility?.grade == .safe
        case .review: return candidate.compatibility?.grade == .popupRisk
        case .blocked: return candidate.compatibility?.grade == .blocked
        case .unknown: return candidate.compatibility == nil
        }
    }
}

/// Status choices for the restore-application list filter.
public enum RestoreStatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case managed
    case unmanaged
    case unconfirmed
    case unresolved

    public var label: String {
        switch self {
        case .all: return "All"
        case .managed: return "Managed"
        case .unmanaged: return "Unmanaged"
        case .unconfirmed: return "Unconfirmed"
        case .unresolved: return "Unresolved"
        }
    }

    fileprivate func matches(_ item: RestoreItem) -> Bool {
        switch self {
        case .all: return true
        case .managed: return item.status == .managed
        case .unmanaged: return item.status == .unmanaged
        case .unconfirmed: return item.status == .unconfirmed
        case .unresolved:
            if case .unresolved = item.status { return true }
            return false
        }
    }
}

/// Size thresholds use the same 1024-based units as the rest of the TUI.
public enum TUISizeFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case atLeast1GB
    case atLeast5GB
    case atLeast10GB

    public var label: String {
        switch self {
        case .all: return "All sizes"
        case .atLeast1GB: return "≥ 1 GB"
        case .atLeast5GB: return "≥ 5 GB"
        case .atLeast10GB: return "≥ 10 GB"
        }
    }

    public var minimumBytes: UInt64? {
        let gb = UInt64(1024 * 1024 * 1024)
        switch self {
        case .all: return nil
        case .atLeast1GB: return gb
        case .atLeast5GB: return gb * 5
        case .atLeast10GB: return gb * 10
        }
    }

    public func matches(_ sizeBytes: UInt64?) -> Bool {
        guard let minimumBytes else { return true }
        guard let sizeBytes else { return false }
        return sizeBytes >= minimumBytes
    }
}

public struct TUIState: Equatable {
    public var currentScreen: TUIScreen = .home
    public var navigationStack: [TUIScreen] = []

    public var sessionVolumePath: String?
    public var eligibleVolumesList: [StorageVolume] = []

    public var cachedStatus: StatusReport?
    public var cachedScan: ScanReport?
    public var cachedDoctor: DoctorReport?
    public var cachedExplorer: ExplorerScanReport?
    public var explorerLoaded = false
    public var explorerLoading = false
    public var explorerRoot: String = NSHomeDirectory() + "/Library/Application Support"
    public var explorerIndex = 0
    public var explorerScrollOffset = 0
    public var explorerSearch = ""
    public var explorerSortByName = false

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
    public var moveStatusFilter: MoveStatusFilter = .all
    public var moveSizeFilter: TUISizeFilter = .all
    public var restoreStatusFilter: RestoreStatusFilter = .all
    public var restoreSizeFilter: TUISizeFilter = .all
    public var moveFilterStatusDraft: MoveStatusFilter = .all
    public var moveFilterSizeDraft: TUISizeFilter = .all
    public var restoreFilterStatusDraft: RestoreStatusFilter = .all
    public var restoreFilterSizeDraft: TUISizeFilter = .all
    /// The active row in the filter screen: 0 = status, 1 = size.
    public var filterFieldIndex = 0
    public var moveSortByName = false
    public var restoreSortBySize = false

    // Compatibility accessors for callers that used the original single-toggle filters.
    public var moveEligibleOnly: Bool {
        get { moveStatusFilter == .safe }
        set { moveStatusFilter = newValue ? .safe : .all }
    }

    public var restoreManagedOnly: Bool {
        get { restoreStatusFilter == .managed }
        set { restoreStatusFilter = newValue ? .managed : .all }
    }

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
            .filter { moveStatusFilter.matches($0) }
            .filter { moveSizeFilter.matches($0.sizeBytes) }
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
            .filter { restoreStatusFilter.matches($0) }
            .filter { restoreSizeFilter.matches($0.sizeBytes) }
            .sorted {
                if restoreSortBySize, $0.sizeBytes != $1.sizeBytes { return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public var doctorFindings: [DoctorFinding] {
        cachedDoctor?.findings ?? []
    }

    public var explorerEntries: [ExplorerEntry] {
        guard let report = cachedExplorer else { return [] }
        let filtered = report.entries.filter {
            explorerSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(explorerSearch)
        }
        if explorerSortByName {
            return filtered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return filtered
    }

    public var explorerDeltaByPath: [String: ExplorerDelta] {
        Dictionary(uniqueKeysWithValues: (cachedExplorer?.deltas ?? []).map { ($0.path, $0) })
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
