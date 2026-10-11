import Foundation
import CryptoKit

public struct XcodeStoragePlan: Equatable, Sendable {
    public let volumePath: String
    public let volumeUUID: String?
    public let availableBytes: UInt64
    public let requiredBytes: UInt64
    public let options: XcodeDoctorOptions
    public let report: XcodeDoctorReport
    public let xcodeRunning: Bool
    public let unavailableSimulatorIDs: [String]
    public let fingerprints: [String: String]

    public init(volumePath: String, volumeUUID: String?, availableBytes: UInt64, requiredBytes: UInt64,
                options: XcodeDoctorOptions, report: XcodeDoctorReport, xcodeRunning: Bool,
                unavailableSimulatorIDs: [String], fingerprints: [String: String]) {
        self.volumePath = volumePath
        self.volumeUUID = volumeUUID
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
        self.options = options
        self.report = report
        self.xcodeRunning = xcodeRunning
        self.unavailableSimulatorIDs = unavailableSimulatorIDs
        self.fingerprints = fingerprints
    }

    /// Free space can fluctuate without changing the actions. A fresh plan still checks sufficiency.
    public func hasSameConditions(as other: XcodeStoragePlan) -> Bool {
        volumePath == other.volumePath && volumeUUID == other.volumeUUID
            && requiredBytes == other.requiredBytes && options == other.options
            && report == other.report && xcodeRunning == other.xcodeRunning
            && unavailableSimulatorIDs == other.unavailableSimulatorIDs && fingerprints == other.fingerprints
    }
}

public enum XcodePlanError: LocalizedError, Equatable {
    case conditionsChanged(String)

    public var errorDescription: String? {
        switch self {
        case .conditionsChanged(let reason):
            return "Xcode storage conditions changed. No actions were executed. Review a fresh preview. \(reason)"
        }
    }
}

public struct XcodeActionFailure: Codable, Equatable, Sendable {
    public let action: String
    public let reason: String

    public init(action: String, reason: String) {
        self.action = action
        self.reason = reason
    }
}

public extension XcodeDoctorOptions {
    var actionDescriptions: [String] {
        var actions: [String] = []
        if externalizeDeviceSupport { actions.append("externalize Xcode DeviceSupport") }
        if externalizeArchives { actions.append("externalize Archives") }
        actions.append("delete unavailable simulators")
        if externalizeDerivedData { actions.append("externalize DerivedData") }
        if cleanDerivedData { actions.append("clean DerivedData") }
        if cleanCaches { actions.append("clean simulator and Xcode caches") }
        return actions
    }
}

/// Bounded metadata snapshots detect replaced paths, link changes and same-size file edits.
/// Access times are excluded because reading the preview must not invalidate it.
struct XcodePathFingerprinter {
    let fileManager: FileManager
    static let maximumEntries = 100_000

    func fingerprint(_ root: URL, recursive: Bool) throws -> String {
        var hash = SHA256()
        var count = 0
        func add(_ value: String) { hash.update(data: Data((value + "\u{0000}").utf8)) }
        func visit(_ url: URL, recurse: Bool) throws {
            count += 1
            guard count <= Self.maximumEntries else {
                throw MacBayError.unsupportedOperation("Xcode preview exceeded \(Self.maximumEntries) entries at \(root.path). Reduce the selected scope before retrying.")
            }
            add(url.path)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                add("missing")
                return
            }
            for key in [FileAttributeKey.type, .systemFileNumber, .systemNumber, .size, .modificationDate, .creationDate, .posixPermissions] {
                if let date = attributes[key] as? Date {
                    add(String(date.timeIntervalSinceReferenceDate))
                } else {
                    add(String(describing: attributes[key]))
                }
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                add(try fileManager.destinationOfSymbolicLink(atPath: url.path))
            } else if recurse, attributes[.type] as? FileAttributeType == .typeDirectory {
                let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for child in children.sorted(by: { $0.path < $1.path }) { try visit(child, recurse: true) }
            }
        }
        try visit(root, recurse: recursive)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
