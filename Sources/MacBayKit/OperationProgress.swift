import Foundation

/// Execution events independent of terminal presentation. Copy samples are estimates, not verification.
public enum OperationProgress: Sendable {
    case selectingVolume, validating, checkingProcesses, verifyingSignature
    case checkingCompatibility, inspectingStorage, copying, moving, updatingLink
    case savingManifest, refreshingDock
    case copyProgress(CopyProgress)
}

public typealias ProgressHandler = (OperationProgress) -> Void

public struct CopyProgress: Equatable, Sendable {
    public let observedBytes: UInt64
    public let totalBytes: UInt64
    public let elapsed: TimeInterval

    public init(observedBytes: UInt64, totalBytes: UInt64, elapsed: TimeInterval) {
        self.observedBytes = min(observedBytes, totalBytes)
        self.totalBytes = totalBytes
        self.elapsed = max(0, elapsed)
    }

    // File lengths can be preallocated. Never claim completion before ditto exits
    // and signature verification finishes.
    public var fraction: Double { totalBytes == 0 ? 0 : min(0.99, Double(observedBytes) / Double(totalBytes)) }
    public var bytesPerSecond: UInt64? {
        guard elapsed >= 1, observedBytes > 0 else { return nil }
        return UInt64(min(Double(UInt64.max / 2), Double(observedBytes) / elapsed))
    }
}

/// Best-effort bounded sampling of destination file lengths, never following symlinks.
struct CopyProgressSampler {
    let destination: URL
    let totalBytes: UInt64
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastSample: TimeInterval = -.infinity

    init(destination: URL, totalBytes: UInt64) {
        self.destination = destination
        self.totalBytes = totalBytes
    }

    mutating func sample() -> CopyProgress? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 2 else { return nil }
        lastSample = now
        var readable = true
        guard let entries = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, _ in readable = false; return false }
        ) else { return nil }
        var bytes: UInt64 = 0
        for case let url as URL in entries {
            guard ProcessInfo.processInfo.systemUptime - now < 0.2,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return nil }
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            if values.isRegularFile == true {
                let sum = bytes.addingReportingOverflow(UInt64(max(0, values.fileSize ?? 0)))
                guard !sum.overflow else { return nil }
                bytes = sum.partialValue
            }
        }
        guard readable else { return nil }
        return CopyProgress(observedBytes: bytes, totalBytes: totalBytes, elapsed: now - started)
    }
}
