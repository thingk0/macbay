import Foundation
import MacBayKit

public struct DefaultTUIService: @unchecked Sendable, TUIServiceProtocol {
    private let fileManager: FileManager
    private let service: MacBayService
    private let volumeManager: VolumeManager
    private let configStore: ConfigStore
    private let applicationDirectories: [URL]?

    public init(
        fileManager: FileManager = .default,
        service: MacBayService? = nil,
        volumeManager: VolumeManager? = nil,
        configStore: ConfigStore? = nil,
        applicationDirectories: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.service = service ?? MacBayService(fileManager: fileManager)
        self.volumeManager = volumeManager ?? VolumeManager(fileManager: fileManager)
        self.configStore = configStore ?? ConfigStore(fileManager: fileManager)
        self.applicationDirectories = applicationDirectories
    }

    public func loadStatus() throws -> StatusReport {
        try service.status()
    }

    public func loadScan() throws -> ScanReport {
        if let applicationDirectories {
            return service.scan(applicationDirectories: applicationDirectories)
        } else {
            return service.scan()
        }
    }

    public func loadDoctor(volumePath: String?) throws -> DoctorReport {
        try service.doctor(volumePath: volumePath)
    }

    public func eligibleVolumes() throws -> [StorageVolume] {
        try volumeManager.externalVolumes()
    }

    public func defaultVolume() throws -> DefaultVolume? {
        try configStore.load().defaultVolume
    }

    public func dock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        force: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        try service.dock(
            appName: appName,
            volumePath: volumePath,
            dryRun: dryRun,
            force: force,
            progress: progress
        )
    }

    public func undock(
        appName: String,
        volumePath: String?,
        dryRun: Bool,
        progress: ProgressHandler?
    ) throws -> MigrationResult {
        try service.undock(
            appName: appName,
            volumePath: volumePath,
            dryRun: dryRun,
            progress: progress
        )
    }
}
