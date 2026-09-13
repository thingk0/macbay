import Foundation

public protocol VolumeOperationLocking: Sendable {
    func withVolumeLock<T>(on volume: URL, _ body: () throws -> T) throws -> T
}

public struct VolumeOperationLock: VolumeOperationLocking {
    private static let guardLock = NSLock()
    private nonisolated(unsafe) static var heldPaths: [String: ObjectIdentifier] = [:]

    public init() {}

    public func withVolumeLock<T>(on volume: URL, _ body: () throws -> T) throws -> T {
        let lockURL = MacBayPaths.operationLockURL(on: volume)
        let key = lockURL.standardizedFileURL.path
        let owner = ObjectIdentifier(Thread.current)

        Self.guardLock.lock()
        if let holder = Self.heldPaths[key] {
            Self.guardLock.unlock()
            if holder == owner {
                return try body()
            }
            throw MacBayError.volumeBusy(path: volume.path, locks: [lockURL.path])
        }
        Self.heldPaths[key] = owner
        Self.guardLock.unlock()

        defer {
            Self.guardLock.lock()
            Self.heldPaths.removeValue(forKey: key)
            Self.guardLock.unlock()
        }

        do {
            return try FileLock(url: lockURL).withLock(blocking: false) {
                try body()
            }
        } catch MacBayError.operationInProgress(let path, _) where path == lockURL.path {
            throw MacBayError.volumeBusy(path: volume.path, locks: [lockURL.path])
        }
    }
}

public struct NoOpVolumeOperationLock: VolumeOperationLocking {
    public init() {}

    public func withVolumeLock<T>(on volume: URL, _ body: () throws -> T) throws -> T {
        try body()
    }
}
