import Foundation

public struct DarwinRepairSafetyInspector: RepairSafetyInspector, @unchecked Sendable {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let processInspector: ProcessInspector
    private let appInspector: AppInspector
    private let sizeCalculator: FileSizeCalculator

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.processInspector = ProcessInspector(commandRunner: commandRunner, fileManager: fileManager)
        self.appInspector = AppInspector(fileManager: fileManager, commandRunner: commandRunner)
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
    }

    public func inspectBundle(at url: URL) throws -> AppCopyInfo {
        let stdURL = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: stdURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw MacBayError.invalidApplication(stdURL.path)
        }

        let infoPlistURL = stdURL.appendingPathComponent("Contents/Info.plist")
        var bundleId: String?
        var version: String?
        var build: String?

        if fileManager.fileExists(atPath: infoPlistURL.path),
           let data = try? Data(contentsOf: infoPlistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            bundleId = plist["CFBundleIdentifier"] as? String
            version = plist["CFBundleShortVersionString"] as? String
            build = plist["CFBundleVersion"] as? String
        }

        let sizeBytes = (try? sizeCalculator.size(of: stdURL)) ?? 0

        var sigStatus = "Valid"
        var sigDetails: String?
        let signResult = try? commandRunner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", stdURL.path]
        )
        if let signResult = signResult {
            if signResult.status != 0 {
                sigStatus = "Invalid"
                sigDetails = signResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            sigStatus = "Unchecked"
        }

        let assessment = appInspector.assess(bundleURL: stdURL)
        let gradeStr: String
        switch assessment.grade {
        case .safe:
            gradeStr = "Safe"
        case .popupRisk:
            gradeStr = "PopupRisk"
        case .blocked:
            gradeStr = "Blocked"
        }

        return AppCopyInfo(
            path: stdURL.path,
            bundleIdentifier: bundleId,
            version: version,
            buildNumber: build,
            sizeBytes: sizeBytes,
            signatureStatus: sigStatus,
            signatureDetails: sigDetails,
            compatibilityGrade: gradeStr,
            compatibilityReasons: assessment.reasons
        )
    }

    public func assertSafeToOperate(at urls: [URL]) throws {
        for url in urls {
            if fileManager.fileExists(atPath: url.path) {
                try processInspector.assertSafeToMove(path: url)
            }
        }
    }

    public func assessCompatibility(at url: URL) -> CompatibilityAssessment {
        appInspector.assess(bundleURL: url.standardizedFileURL)
    }
}

public struct DarwinRepairBundleOperations: RepairBundleOperations, @unchecked Sendable {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let sizeCalculator: FileSizeCalculator

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
    }

    public func fileExists(at url: URL) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return true
        }
        return fileManager.fileExists(atPath: url.path)
    }

    public func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public func calculateSizeBytes(at url: URL) throws -> UInt64 {
        try sizeCalculator.size(of: url)
    }

    public func copyBundle(from source: URL, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let dittoResult = try? commandRunner.run(
            "/usr/bin/ditto",
            arguments: [source.path, destination.path]
        )
        if let dittoResult = dittoResult, dittoResult.status == 0 {
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    public func moveBundle(from source: URL, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    public func remove(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fileManager.removeItem(at: url)
        }
    }

    public func createSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws {
        let parentDir = symlinkURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
    }
}

public struct DarwinRepairManifestRepository: RepairManifestRepository, @unchecked Sendable {
    private let manifestStore: ManifestStore

    public init(fileManager: FileManager = .default) {
        self.manifestStore = ManifestStore(fileManager: fileManager)
    }

    public func findItem(named appName: String, on volume: URL) throws -> DockedItem? {
        let manifest = try manifestStore.load(on: volume)
        return manifest.items.first {
            $0.name == appName ||
            $0.name == "\(appName).app" ||
            $0.sourcePath.hasSuffix("/\(appName)") ||
            $0.sourcePath.hasSuffix("/\(appName).app")
        }
    }

    public func removeItem(named appName: String, on volume: URL) throws {
        try manifestStore.updating(on: volume) { manifest in
            manifest.items.removeAll {
                $0.name == appName ||
                $0.name == "\(appName).app" ||
                $0.sourcePath.hasSuffix("/\(appName)") ||
                $0.sourcePath.hasSuffix("/\(appName).app")
            }
        }
    }

    public func recordItem(_ item: DockedItem, on volume: URL) throws {
        try manifestStore.updating(on: volume) { manifest in
            manifest.items.removeAll {
                $0.name == item.name ||
                $0.sourcePath == item.sourcePath
            }
            manifest.items.append(item)
        }
    }
}

public struct DarwinRepairJournal: RepairJournaling, @unchecked Sendable {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    private func recordURL(for appName: String, on volume: URL) -> URL {
        let safeName = appName.replacingOccurrences(of: "/", with: "_")
        return MacBayPaths.operationsRoot(on: volume).appendingPathComponent("repair-\(safeName).json")
    }

    public func save(_ record: RepairJournalRecord, on volume: URL) throws {
        let dir = MacBayPaths.operationsRoot(on: volume)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = recordURL(for: record.appName, on: volume)
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func load(appName: String, on volume: URL) -> RepairJournalRecord? {
        let url = recordURL(for: appName, on: volume)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(RepairJournalRecord.self, from: data)
    }

    public func remove(appName: String, on volume: URL) {
        let url = recordURL(for: appName, on: volume)
        try? fileManager.removeItem(at: url)
    }

    public func listIncomplete(on volume: URL) -> [RepairJournalRecord] {
        let dir = MacBayPaths.operationsRoot(on: volume)
        guard fileManager.fileExists(atPath: dir.path),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.lastPathComponent.hasPrefix("repair-") && $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(RepairJournalRecord.self, from: data),
                  record.phase != .completed else {
                return nil
            }
            return record
        }
    }
}

public struct DarwinRepairVolumeInspector: RepairVolumeInspector, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func availableBytes(on volume: URL) throws -> UInt64 {
        let values = try fileManager.attributesOfFileSystem(forPath: volume.path)
        if let freeSize = values[.systemFreeSize] as? NSNumber {
            return freeSize.uint64Value
        }
        return 0
    }

    public func isWritable(volume: URL) -> Bool {
        fileManager.isWritableFile(atPath: volume.path)
    }
}
