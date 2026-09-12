import Foundation

public struct SymlinkSwapRollbackToken: Sendable {
    public let symlinkURL: URL
    public let originalTarget: String?

    public init(symlinkURL: URL, originalTarget: String?) {
        self.symlinkURL = symlinkURL
        self.originalTarget = originalTarget
    }
}

public protocol AppSafetyInspector: Sendable {
    func inspectSymlink(at source: URL) throws -> SymlinkResolution
    func assertNoActiveProcessesOrLocks(at target: URL) throws
    func verifyCodeSignature(at target: URL) throws
    func assessCompatibility(at target: URL) -> CompatibilityAssessment
}

public protocol BundleFileOperations: Sendable {
    func moveBundle(from source: URL, to destination: URL) throws
    func atomicReplaceSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws -> SymlinkSwapRollbackToken
    func rollbackSymlink(using token: SymlinkSwapRollbackToken) throws
    func rollbackMove(from destination: URL, to source: URL) throws
    func fileExists(at url: URL) -> Bool
    func calculateSizeBytes(at url: URL) throws -> UInt64
}

public protocol ManifestRepository: Sendable {
    func load(on volume: URL) throws -> DockManifest
    func update(on volume: URL, mutate: (inout DockManifest) throws -> Void) throws
}

public protocol OperationJournaling: Sendable {
    func record(operation: AdoptOperationRecord, on volume: URL) throws
    func remove(appName: String, on volume: URL) throws
    func load(appName: String, on volume: URL) -> AdoptOperationRecord?
}

public protocol SystemEnvironmentRefresher: Sendable {
    func refreshLaunchServices(for bundleURL: URL)
    func restartDock()
}

public protocol VolumeStorageInspector: Sendable {
    func diskInfo(for path: String) throws -> VolumeDiskInfo
    func eligibilityCheck(for info: VolumeDiskInfo) -> (isEligible: Bool, reason: String?)
}
