import Foundation

public struct DarwinRepairBackupFileSystem: RepairBackupFileSystem, @unchecked Sendable {
    private static let maximumJournalSizeBytes: UInt64 = 1_048_576

    private let fileManager: FileManager
    private let sizeCalculator: FileSizeCalculator

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
    }

    public func kind(of url: URL) -> RepairBackupFileKind {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                return .directory
            case .typeRegular:
                return .file
            case .typeSymbolicLink:
                return .symbolicLink
            default:
                return .unreadable
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return .missing
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
                return .missing
            }
            return .unreadable
        }
    }

    public func directoryEntries(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    }

    public func size(of url: URL) throws -> UInt64 {
        try sizeCalculator.size(of: url)
    }

    public func bundleMetadata(at url: URL) -> RepairBackupBundleMetadata {
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        let contentsKind = kind(of: contentsURL)
        guard contentsKind == .directory else {
            return RepairBackupBundleMetadata(
                isVerifiable: false,
                reason: "Backup bundle has no readable Contents directory."
            )
        }

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let infoPlistKind = kind(of: infoPlistURL)
        guard infoPlistKind == .file else {
            return RepairBackupBundleMetadata(
                isVerifiable: false,
                reason: "Backup bundle has no readable Info.plist."
            )
        }

        guard let data = try? Data(contentsOf: infoPlistURL) else {
            return RepairBackupBundleMetadata(
                isVerifiable: false,
                reason: "Backup bundle Info.plist could not be read."
            )
        }

        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return RepairBackupBundleMetadata(
                isVerifiable: false,
                reason: "Backup bundle Info.plist could not be parsed."
            )
        }

        return RepairBackupBundleMetadata(
            version: plist["CFBundleShortVersionString"] as? String,
            buildNumber: plist["CFBundleVersion"] as? String,
            isVerifiable: true
        )
    }

    public func creationDate(of url: URL) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
    }

    public func removeItem(at url: URL) throws {
        try fileManager.removeItemMakingWritable(at: url)
    }

    public func isDirectoryEmpty(at url: URL) throws -> Bool {
        try directoryEntries(at: url).isEmpty
    }

    public func availableBytes(on volume: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfFileSystem(forPath: volume.path)
        guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            throw MacBayError.spaceCheckFailed(
                path: volume.path,
                details: "Free space is unavailable for this volume."
            )
        }
        return freeSize.uint64Value
    }

    public func journalFiles(on volume: URL) -> RepairBackupJournalScan {
        let root = MacBayPaths.operationsRoot(on: volume)
        switch kind(of: root) {
        case .missing:
            return RepairBackupJournalScan(files: [], isComplete: true)
        case .symbolicLink:
            return RepairBackupJournalScan(
                files: [],
                isComplete: false,
                warnings: ["Operation journals at \(root.path) are a symbolic link; their contents were not followed."]
            )
        case .file, .unreadable:
            return RepairBackupJournalScan(
                files: [],
                isComplete: false,
                warnings: ["Operation journals at \(root.path) are not a readable directory."]
            )
        case .directory:
            break
        }

        let entries: [URL]
        do {
            entries = try directoryEntries(at: root).sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
        } catch {
            return RepairBackupJournalScan(
                files: [],
                isComplete: false,
                warnings: ["Operation journals at \(root.path) could not be listed: \(error.localizedDescription)"]
            )
        }

        var files: [RepairBackupJournalFile] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard entry.pathExtension.lowercased() == "json", !name.hasPrefix("._") else {
                continue
            }
            switch kind(of: entry) {
            case .directory:
                // Staging directories are not journals.
                continue
            case .file:
                files.append(RepairBackupJournalFile(path: entry.path, contents: readJournal(at: entry)))
            case .missing, .symbolicLink, .unreadable:
                files.append(RepairBackupJournalFile(path: entry.path, contents: nil))
            }
        }
        return RepairBackupJournalScan(files: files, isComplete: true)
    }

    private func readJournal(at url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= Self.maximumJournalSizeBytes,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
