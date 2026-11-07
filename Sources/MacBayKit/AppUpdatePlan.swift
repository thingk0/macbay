import Foundation

public enum AppUpdateAction: String, Equatable, Sendable {
    case begin, finish, managedKiro
}

/// A dry-run plus the exact workflow, paths and volume identity the user reviewed.
public struct AppUpdatePlan: Equatable, Sendable {
    public let action: AppUpdateAction
    public let appPath: String
    public let resolvedVolumePath: String
    public let report: UpdateWorkflowReport
    public let existingRecord: UpdateWorkflowRecord?
    public let fingerprints: [String: String]

    public var requiresForce: Bool { report.migration?.compatibility?.grade == .popupRisk && action == .finish }

    public func hasSameConditions(as other: AppUpdatePlan) -> Bool {
        let left = report, right = other.report
        // New workflows receive a timestamp on every dry run. Existing records must match exactly.
        return action == other.action && appPath == other.appPath && resolvedVolumePath == other.resolvedVolumePath
            && existingRecord == other.existingRecord
            && fingerprints == other.fingerprints
            && left.record.appName == right.record.appName
            && left.record.sourcePath == right.record.sourcePath
            && left.record.externalPath == right.record.externalPath
            && left.record.bundleIdentifier == right.record.bundleIdentifier
            && left.record.volumePath == right.record.volumePath
            && left.record.volumeUUID == right.record.volumeUUID
            && left.record.phase == right.record.phase
            && left.currentVersion == right.currentVersion && left.currentBuild == right.currentBuild
            && left.migration?.sourcePath == right.migration?.sourcePath
            && left.migration?.destinationPath == right.migration?.destinationPath
            && left.migration?.sizeBytes == right.migration?.sizeBytes
            && left.migration?.compatibility == right.migration?.compatibility
    }
}
