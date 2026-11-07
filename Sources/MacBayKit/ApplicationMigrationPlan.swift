import Foundation

public enum ApplicationMigrationAction: String, Equatable, Sendable { case move, restore }

public struct ApplicationMigrationPlan: Equatable, Sendable {
    public let action: ApplicationMigrationAction
    public let appPath: String
    public let volumePath: String
    public let volumeUUID: String
    public let report: MigrationResult
    public let fingerprints: [String: String]
    public var requiresForce: Bool { action == .move && report.compatibility?.grade == .popupRisk }
}

public struct CachePurgePlan: Equatable, Sendable {
    public let items: [PurgeItem]
    public let fingerprints: [String: String]
}

public struct DefaultVolumePlan: Equatable, Sendable {
    public let volume: StorageVolume
    public let volumeUUID: String
    public let previousDefault: DefaultVolume?
}
