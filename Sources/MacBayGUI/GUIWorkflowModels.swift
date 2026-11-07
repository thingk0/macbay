import Foundation
import MacBayKit

public struct GUIUpdateRequest: Equatable, Sendable {
    public let action: AppUpdateAction
    public let appPath: String
    public let expectedRecord: UpdateWorkflowRecord?
    public init(action: AppUpdateAction, appPath: String, expectedRecord: UpdateWorkflowRecord? = nil) {
        self.action = action; self.appPath = appPath; self.expectedRecord = expectedRecord
    }
}

public enum GUIActionKind: Equatable, Sendable {
    case update(AppUpdateAction)
    case repairRollback
    case migration(ApplicationMigrationAction)
    case cleanup
    case xcode
}

public struct GUIActionPreview: Identifiable, Sendable {
    public let id: UUID
    public let kind: GUIActionKind
    public let detail: GUIPreview
    public let confirmTitle: String
    public let requiresRiskAcknowledgment: Bool
    public let canExecute: Bool
    public let blockedReason: String?
    public let requiresXcodeRemovalConfirmation: Bool
    public var requiresVendorFinished: Bool { kind == .update(.finish) }
    public var requiresCacheRemovalConfirmation: Bool { kind == .cleanup }
    public func accepts(_ confirmation: GUIActionConfirmation) -> Bool {
        id == confirmation.previewID && canExecute && confirmation.reviewed
            && (!requiresRiskAcknowledgment || confirmation.acknowledgesRisks)
            && (!requiresVendorFinished || confirmation.vendorFinished)
            && (!requiresCacheRemovalConfirmation || confirmation.confirmsCacheRemoval)
            && (!requiresXcodeRemovalConfirmation || confirmation.confirmsXcodeRemoval)
    }
    public init(id: UUID = UUID(), kind: GUIActionKind, detail: GUIPreview, confirmTitle: String,
                requiresRiskAcknowledgment: Bool = false, canExecute: Bool = true,
                requiresXcodeRemovalConfirmation: Bool = false, blockedReason: String? = nil) {
        self.id = id; self.kind = kind; self.detail = detail; self.confirmTitle = confirmTitle
        self.requiresRiskAcknowledgment = requiresRiskAcknowledgment; self.canExecute = canExecute
        self.requiresXcodeRemovalConfirmation = requiresXcodeRemovalConfirmation
        self.blockedReason = blockedReason
    }
}

public struct GUIActionConfirmation: Sendable {
    public let previewID: UUID
    public let reviewed: Bool
    public let acknowledgesRisks: Bool
    public let vendorFinished: Bool
    public let confirmsCacheRemoval: Bool
    public let confirmsXcodeRemoval: Bool
    public init(previewID: UUID, reviewed: Bool, acknowledgesRisks: Bool = false, vendorFinished: Bool = false,
                confirmsCacheRemoval: Bool = false, confirmsXcodeRemoval: Bool = false) {
        self.previewID = previewID; self.reviewed = reviewed
        self.acknowledgesRisks = acknowledgesRisks; self.vendorFinished = vendorFinished
        self.confirmsCacheRemoval = confirmsCacheRemoval
        self.confirmsXcodeRemoval = confirmsXcodeRemoval
    }
}

public struct GUIActionResult: Sendable {
    public let succeeded: Bool
    public let title: String
    public let messages: [String]
    public let paths: [String]
    public let canOpenRecovery: Bool
    public init(succeeded: Bool, title: String, messages: [String], paths: [String] = [], canOpenRecovery: Bool = false) {
        self.succeeded = succeeded; self.title = title; self.messages = messages
        self.paths = paths; self.canOpenRecovery = canOpenRecovery
    }
}

public struct GUIActionProgress: Sendable {
    public let message: String
    public let fraction: Double?
    public init(_ message: String, fraction: Double? = nil) { self.message = message; self.fraction = fraction }
    init(_ event: OperationProgress) {
        fraction = { if case .copyProgress(let copy) = event { return copy.fraction }; return nil }()
        switch event {
        case .selectingVolume: message = "Checking the original volume…"
        case .validating: message = "Validating application paths…"
        case .checkingProcesses: message = "Checking running apps and locks…"
        case .verifyingSignature: message = "Verifying code signature…"
        case .checkingCompatibility: message = "Checking compatibility…"
        case .inspectingStorage: message = "Checking available space…"
        case .copying: message = "Copying or running the vendor updater…"
        case .moving: message = "Moving the verified app…"
        case .updatingLink: message = "Updating the original app link…"
        case .savingManifest: message = "Saving the operation record…"
        case .refreshingDock: message = "Refreshing application registration…"
        case .removingBackup: message = "Completing the operation…"
        case .copyProgress(let copy):
            message = "Copying \(GUIFormat.bytes(copy.observedBytes)) of \(GUIFormat.bytes(copy.totalBytes))…"
        }
    }
}
