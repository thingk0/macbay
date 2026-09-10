import Foundation

public struct SpaceEstimate: Equatable, Sendable {
    public let copyBytes: UInt64
    public let destinationPath: String
    public let destinationAvailableBytes: UInt64?
    public let destinationFreeAfterCopyBytes: Int64?
    public let shortfallBytes: UInt64
    public let internalFreedBytes: UInt64?

    public var isVerifiable: Bool { destinationAvailableBytes != nil }
    public var isSufficient: Bool { isVerifiable && shortfallBytes == 0 }

    public init(
        copyBytes: UInt64,
        destinationPath: String,
        destinationAvailableBytes: UInt64?,
        destinationFreeAfterCopyBytes: Int64?,
        shortfallBytes: UInt64,
        internalFreedBytes: UInt64?
    ) {
        self.copyBytes = copyBytes
        self.destinationPath = destinationPath
        self.destinationAvailableBytes = destinationAvailableBytes
        self.destinationFreeAfterCopyBytes = destinationFreeAfterCopyBytes
        self.shortfallBytes = shortfallBytes
        self.internalFreedBytes = internalFreedBytes
    }

    public func reportLines() -> [String] {
        var lines: [String] = []

        if let availableBytes = destinationAvailableBytes {
            lines.append("Space: destination free \(OutputFormatter.humanBytes(availableBytes)) on \(destinationPath)")
        } else {
            lines.append("Space: free space on \(destinationPath) could not be read; a real run stops before copying")
        }

        if let freeAfterCopyBytes = destinationFreeAfterCopyBytes {
            lines.append("Space: estimated free after copy \(OutputFormatter.humanSignedBytes(freeAfterCopyBytes))")
        }

        if shortfallBytes > 0 {
            lines.append("Space: insufficient — \(OutputFormatter.humanBytes(shortfallBytes)) short on \(destinationPath)")
        }

        if let internalFreedBytes, internalFreedBytes > 0 {
            lines.append("Space: estimated internal space freed \(OutputFormatter.humanBytes(internalFreedBytes)) (logical size estimate; APFS shared blocks and snapshots can change the actual amount)")
        }

        return lines
    }
}

public struct SpaceEstimator {
    private let diskInfoProvider: any DiskInfoProvider

    public init(diskInfoProvider: any DiskInfoProvider = SystemDiskInfoProvider()) {
        self.diskInfoProvider = diskInfoProvider
    }

    public func estimate(
        copyBytes: UInt64,
        destinationVolume: URL,
        internalFreedBytes: UInt64? = nil
    ) -> SpaceEstimate {
        let availableBytes = try? resolvedAvailableBytes(for: destinationVolume)
        return SpaceEstimate(
            copyBytes: copyBytes,
            destinationPath: destinationVolume.path,
            destinationAvailableBytes: availableBytes,
            destinationFreeAfterCopyBytes: availableBytes.map { Int64(clamping: $0) - Int64(clamping: copyBytes) },
            shortfallBytes: availableBytes.map { copyBytes > $0 ? copyBytes - $0 : 0 } ?? 0,
            internalFreedBytes: internalFreedBytes
        )
    }

    public func requireSufficientSpace(copyBytes: UInt64, destinationVolume: URL) throws {
        let availableBytes = try resolvedAvailableBytes(for: destinationVolume)
        guard copyBytes <= availableBytes else {
            throw MacBayError.insufficientSpace(
                path: destinationVolume.path,
                neededBytes: copyBytes,
                availableBytes: availableBytes
            )
        }
    }

    private func resolvedAvailableBytes(for destinationVolume: URL) throws -> UInt64 {
        let info: VolumeDiskInfo
        do {
            info = try diskInfoProvider.diskInfo(for: destinationVolume.path)
        } catch {
            throw MacBayError.spaceCheckFailed(
                path: destinationVolume.path,
                details: error.localizedDescription
            )
        }
        guard info.totalBytes > 0 else {
            throw MacBayError.spaceCheckFailed(
                path: destinationVolume.path,
                details: "Capacity information is unavailable"
            )
        }
        return info.availableBytes
    }
}
