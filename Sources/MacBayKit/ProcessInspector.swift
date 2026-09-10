import Foundation

public struct ProcessInspector {
    private let commandRunner: any CommandRunner
    private let fileManager: FileManager

    public init(
        commandRunner: any CommandRunner = SystemCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    public func inspect(path: URL) throws -> ProcessInspection {
        let processLocks = try locks(for: path)
        let sqliteLocks = try sqliteLocks(for: path)
        return ProcessInspection(path: path.path, processLocks: processLocks, sqliteLocks: sqliteLocks)
    }

    public func assertSafeToMove(path: URL) throws {
        let inspection = try inspect(path: path)
        if !inspection.processLocks.isEmpty {
            throw MacBayError.activeProcesses(path: path.path, locks: inspection.processLocks)
        }
        if !inspection.sqliteLocks.isEmpty {
            throw MacBayError.sqliteLockDetected(path: path.path, locks: inspection.sqliteLocks)
        }
    }

    public func locks(for path: URL) throws -> [ProcessLock] {
        let result = try commandRunner.run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "+D", path.path]
        )
        if result.status == 1 {
            return []
        }
        guard result.status == 0 else {
            throw MacBayError.commandFailed(
                executable: "/usr/sbin/lsof",
                status: result.status,
                details: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Self.parseLocks(from: result.standardOutput)
    }

    public static func parseLocks(from output: String) -> [ProcessLock] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count >= 9, let pid = Int32(fields[1]) else { return nil }
            return ProcessLock(
                process: String(fields[0]),
                pid: pid,
                user: String(fields[2]),
                fileDescriptor: String(fields[3]),
                path: String(fields[8])
            )
        }
    }

    private func sqliteLocks(for path: URL) throws -> [SQLiteLock] {
        var databases: [URL] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            if Self.isSQLiteDatabase(path) {
                databases = [path]
            }
        } else if let enumerator = fileManager.enumerator(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            while let item = enumerator.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isDirectory != true, Self.isSQLiteDatabase(item) {
                    databases.append(item)
                }
            }
        }

        return databases.flatMap { database in
            ["-wal", "-shm", "-journal"].compactMap { suffix in
                let lockURL = URL(fileURLWithPath: database.path + suffix)
                guard fileManager.fileExists(atPath: lockURL.path) else { return nil }
                return SQLiteLock(databasePath: database.path, lockPath: lockURL.path)
            }
        }
    }

    private static func isSQLiteDatabase(_ url: URL) -> Bool {
        ["db", "sqlite", "sqlite3"].contains(url.pathExtension.lowercased())
    }
}
