/// Execution events independent of terminal presentation. No percentage is implied.
public enum OperationProgress: Sendable {
    case selectingVolume, validating, checkingProcesses, verifyingSignature
    case checkingCompatibility, inspectingStorage, copying, moving, updatingLink
    case savingManifest, refreshingDock
}

public typealias ProgressHandler = (OperationProgress) -> Void
