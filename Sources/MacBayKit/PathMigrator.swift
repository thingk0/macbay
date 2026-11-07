import Foundation

public struct DirectoryMigrator {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let processInspector: ProcessInspector
    private let sizeCalculator: FileSizeCalculator

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        processInspector: ProcessInspector? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.processInspector = processInspector ?? ProcessInspector(
            commandRunner: commandRunner,
            fileManager: fileManager
        )
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
    }

    public func migrate(
        source: URL,
        destination: URL,
        operation: String,
        dryRun: Bool,
        recordOn volume: URL? = nil,
        progress: ProgressHandler? = nil,
        verify: ((URL) throws -> Void)? = nil
    ) throws -> MigrationResult {
        guard fileManager.fileExists(atPath: source.path) else {
            throw MacBayError.pathMissing(source.path)
        }
        guard !isSymbolicLink(source) else {
            throw MacBayError.unsupportedOperation("Source is already a symbolic link: \(source.path)")
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MacBayError.destinationExists(destination.path)
        }

        try processInspector.assertSafeToMove(path: source)
        let sizeBytes = try sizeCalculator.size(of: source)
        var messages: [String] = []

        if dryRun {
            messages.append("Dry run: no files were changed")
            return MigrationResult(
                operation: operation,
                name: source.lastPathComponent,
                sourcePath: source.path,
                destinationPath: destination.path,
                sizeBytes: sizeBytes,
                dryRun: true,
                messages: messages
            )
        }

        let perform = { () throws -> MigrationResult in
            let replacement = SourceLinkReplacement(source: source, destination: destination, fileManager: fileManager)
            let journal = OperationJournal(fileManager: fileManager)
            let record = volume.map { volume in
                MoveOperationRecord(id: UUID().uuidString, kind: .move, name: source.lastPathComponent,
                    sourcePath: source.path, destinationPath: destination.path, backupPath: replacement.backup.path,
                    volumePath: volume.path, phase: .started, timestamp: macBayTimestamp())
            }
            func checkpoint(_ phase: MoveOperationRecord.Phase) throws {
                if let volume, let record { try journal.saveMove(record.updatingPhase(phase), on: volume) }
            }
            if let volume {
                // Fail on an unreadable manifest before changing any source data.
                let manifest = try ManifestStore(fileManager: fileManager).load(on: volume)
                guard manifest.version == DockManifest.currentVersion else {
                    throw MacBayError.unsupportedOperation("The destination manifest version is unsupported. Update MacBay before moving data.")
                }
            }
            try checkpoint(.started)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                progress?(.copying)
                try runDitto(from: source, to: destination, totalBytes: sizeBytes, progress: progress)
                try verify?(destination)
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItemMakingWritable(at: destination)
                }
                if let volume, let record, !fileManager.fileExists(atPath: destination.path) {
                    journal.removeMove(id: record.id, on: volume)
                }
                throw error
            }
            try checkpoint(.copied)
            progress?(.updatingLink)
            try replacement.install()
            try checkpoint(.linkSwapped)
            if let volume {
                progress?(.savingManifest)
                let item = DockedItem(name: source.lastPathComponent, sourcePath: source.path,
                    externalPath: destination.path, sizeBytes: sizeBytes, kind: .directory, dockedAt: macBayTimestamp())
                try ManifestStore(fileManager: fileManager).updating(on: volume) { manifest in
                    manifest.items.removeAll { $0.sourcePath == source.path }
                    manifest.items.append(item)
                }
                try checkpoint(.manifestSaved)
            }
            progress?(.removingBackup)
            try replacement.removeBackup()
            if let volume, let record { journal.removeMove(id: record.id, on: volume) }
            return MigrationResult(operation: operation, name: source.lastPathComponent,
                sourcePath: source.path, destinationPath: destination.path, sizeBytes: sizeBytes,
                dryRun: false, messages: ["Migration completed"])
        }
        if let volume { return try VolumeOperationLock().withVolumeLock(on: volume, perform) }
        return try perform()
    }

    private func runDitto(from source: URL, to destination: URL, totalBytes: UInt64, progress: ProgressHandler?) throws {
        var sampler = CopyProgressSampler(destination: destination, totalBytes: totalBytes)
        let result = try commandRunner.run(
            "/usr/bin/ditto",
            arguments: ["--rsrc", "--extattr", "--acl", source.path, destination.path],
            heartbeat: { if let progress, let sample = sampler.sample() { progress(.copyProgress(sample)) } }
        )
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/bin/ditto",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
