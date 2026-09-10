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
        var messages = [
            "Source: \(source.path)",
            "Destination: \(destination.path)",
            "Size: \(OutputFormatter.humanBytes(sizeBytes))"
        ]

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

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try runDitto(from: source, to: destination)
            try verify?(destination)
            try replaceSourceWithSymlink(source: source, destination: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }

        messages.append("Migration completed")
        return MigrationResult(
            operation: operation,
            name: source.lastPathComponent,
            sourcePath: source.path,
            destinationPath: destination.path,
            sizeBytes: sizeBytes,
            dryRun: false,
            messages: messages
        )
    }

    private func runDitto(from source: URL, to destination: URL) throws {
        let result = try commandRunner.run(
            "/usr/bin/ditto",
            arguments: ["--rsrc", "--extattr", "--acl", source.path, destination.path]
        )
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/bin/ditto",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func replaceSourceWithSymlink(source: URL, destination: URL) throws {
        let backup = source.deletingLastPathComponent().appendingPathComponent(
            ".\(source.lastPathComponent).macbay-\(UUID().uuidString)"
        )
        try fileManager.moveItem(at: source, to: backup)
        do {
            try fileManager.createSymbolicLink(atPath: source.path, withDestinationPath: destination.path)
            try fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: source)
            }
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: backup, to: source)
            }
            throw error
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
