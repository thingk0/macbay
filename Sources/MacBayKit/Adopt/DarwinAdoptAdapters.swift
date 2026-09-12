import Foundation
import Darwin

public struct DarwinAppSafetyInspector: AppSafetyInspector, @unchecked Sendable {
    private let symlinkResolver: SymlinkResolver
    private let processInspector: ProcessInspector
    private let appInspector: AppInspector
    private let commandRunner: any CommandRunner

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.symlinkResolver = SymlinkResolver(fileManager: fileManager)
        self.processInspector = ProcessInspector(commandRunner: commandRunner, fileManager: fileManager)
        self.appInspector = AppInspector(fileManager: fileManager, commandRunner: commandRunner)
        self.commandRunner = commandRunner
    }

    public func inspectSymlink(at source: URL) throws -> SymlinkResolution {
        symlinkResolver.resolve(at: source)
    }

    public func assertNoActiveProcessesOrLocks(at target: URL) throws {
        try processInspector.assertSafeToMove(path: target)
    }

    public func verifyCodeSignature(at target: URL) throws {
        let result = try commandRunner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", target.path]
        )
        guard result.status == 0 else {
            let details = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacBayError.signatureVerificationFailed(path: target.path, details: details)
        }
    }

    public func assessCompatibility(at target: URL) -> CompatibilityAssessment {
        appInspector.assess(bundleURL: target)
    }
}

public struct DarwinBundleFileOperations: BundleFileOperations, @unchecked Sendable {
    private let fileManager: FileManager
    private let sizeCalculator: FileSizeCalculator

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
    }

    public func fileExists(at url: URL) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return true
        }
        return fileManager.fileExists(atPath: url.path)
    }

    public func calculateSizeBytes(at url: URL) throws -> UInt64 {
        try sizeCalculator.size(of: url)
    }

    public func moveBundle(from source: URL, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    public func atomicReplaceSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws -> SymlinkSwapRollbackToken {
        let originalTarget = try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path)
        let tempLink = symlinkURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(symlinkURL.lastPathComponent)")

        try fileManager.createSymbolicLink(at: tempLink, withDestinationURL: targetURL)
        if rename(tempLink.path, symlinkURL.path) != 0 {
            try? fileManager.removeItem(at: tempLink)
            let err = errno
            throw MacBayError.unsupportedOperation("Failed to atomically swap symlink at \(symlinkURL.path): errno \(err)")
        }
        return SymlinkSwapRollbackToken(symlinkURL: symlinkURL, originalTarget: originalTarget)
    }

    public func rollbackSymlink(using token: SymlinkSwapRollbackToken) throws {
        if let orig = token.originalTarget {
            let tempLink = token.symlinkURL.deletingLastPathComponent()
                .appendingPathComponent(".rollback-\(UUID().uuidString)-\(token.symlinkURL.lastPathComponent)")
            try fileManager.createSymbolicLink(atPath: tempLink.path, withDestinationPath: orig)
            if rename(tempLink.path, token.symlinkURL.path) != 0 {
                try? fileManager.removeItem(at: tempLink)
                throw MacBayError.unsupportedOperation("Failed to rollback symlink to \(orig)")
            }
        } else {
            try? fileManager.removeItem(at: token.symlinkURL)
        }
    }

    public func rollbackMove(from destination: URL, to source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let parent = source.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try fileManager.moveItem(at: destination, to: source)
        }
    }
}

public struct DarwinManifestRepository: ManifestRepository, @unchecked Sendable {
    private let manifestStore: ManifestStore

    public init(fileManager: FileManager = .default) {
        self.manifestStore = ManifestStore(fileManager: fileManager)
    }

    public func load(on volume: URL) throws -> DockManifest {
        try manifestStore.load(on: volume)
    }

    public func update(on volume: URL, mutate: (inout DockManifest) throws -> Void) throws {
        try manifestStore.updating(on: volume, mutate)
    }
}

public struct DarwinOperationJournal: OperationJournaling, @unchecked Sendable {
    private let operationJournal: OperationJournal

    public init(fileManager: FileManager = .default) {
        self.operationJournal = OperationJournal(fileManager: fileManager)
    }

    public func record(operation: AdoptOperationRecord, on volume: URL) throws {
        try operationJournal.save(operation, on: volume)
    }

    public func remove(appName: String, on volume: URL) throws {
        operationJournal.remove(for: appName, on: volume)
    }

    public func load(appName: String, on volume: URL) -> AdoptOperationRecord? {
        operationJournal.load(for: appName, on: volume)
    }
}

public struct DarwinSystemEnvironmentRefresher: SystemEnvironmentRefresher, @unchecked Sendable {
    private let dockRefresher: DockRefresher

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.dockRefresher = DockRefresher(fileManager: fileManager, commandRunner: commandRunner)
    }

    public func refreshLaunchServices(for bundleURL: URL) {
        _ = dockRefresher.refresh(for: bundleURL)
    }

    public func restartDock() {
        // DockRefresher.refresh executes both lsregister and killall Dock
    }
}

public struct DarwinVolumeStorageInspector: VolumeStorageInspector, @unchecked Sendable {
    private let volumeManager: VolumeManager

    public init(volumeManager: VolumeManager = VolumeManager()) {
        self.volumeManager = volumeManager
    }

    public func diskInfo(for path: String) throws -> VolumeDiskInfo {
        try volumeManager.diskInfoProvider.diskInfo(for: path)
    }

    public func eligibilityCheck(for info: VolumeDiskInfo) -> (isEligible: Bool, reason: String?) {
        volumeManager.eligibilityCheck(for: info)
    }
}
