import Foundation

public struct RepairRollbackPlan: Equatable, Sendable {
    public let record: RepairJournalRecord
    public let volumeUUID: String
    public let copies: [AppCopyInfo]
    public let fingerprints: [String: String]
}

/// Validates only the existing repair rollback path. Ambiguous phases stay read-only.
struct RepairRollbackPlanner {
    let fileManager: FileManager
    let commandRunner: any CommandRunner
    let applicationsDirectory: URL

    func plan(appName: String, volume: URL, volumeUUID: String) throws -> RepairRollbackPlan {
        let name = URL(fileURLWithPath: appName).lastPathComponent
        guard let record = DarwinRepairJournal(fileManager: fileManager).load(appName: name, on: volume),
              record.phase != .completed, record.schemaVersion == 1 else {
            throw unavailable("No supported interrupted repair journal matches this application.")
        }
        func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        func same(_ left: String, _ right: String) -> Bool { normalized(left) == normalized(right) }
        func safeSegment(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
        }
        let local = URL(fileURLWithPath: record.localPath).standardizedFileURL
        let external = MacBayPaths.applicationsRoot(on: volume).appendingPathComponent(name)
        let backup = URL(fileURLWithPath: record.backupPath).standardizedFileURL
        let backupID = backup.deletingLastPathComponent().lastPathComponent
        let staging = MacBayPaths.operationsRoot(on: volume).appendingPathComponent(".staging-" + backupID).appendingPathComponent(name)
        let localBackup = local.deletingLastPathComponent().appendingPathComponent("." + name + ".macbay-local-backup-" + record.id)
        let allowedParents = [applicationsDirectory, fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard safeSegment(record.id), safeSegment(backupID), record.appName == name, name.hasSuffix(".app"),
              local.lastPathComponent == name,
              allowedParents.contains(where: { same($0.path, local.deletingLastPathComponent().path) }),
              same(record.volumePath, volume.path),
              same(record.externalPath, external.path), backup.lastPathComponent == name,
              same(backup.deletingLastPathComponent().deletingLastPathComponent().path, MacBayPaths.backupsRoot(on: volume).path),
              same(record.stagingPath, staging.path), same(record.localBackupPath, localBackup.path),
              record.originalManifestItem.kind == .application, record.originalManifestItem.name == name,
              same(record.originalManifestItem.sourcePath, local.path),
              same(record.originalManifestItem.externalPath, external.path) else {
            throw unavailable("Repair journal paths do not match the supported MacBay layout.")
        }
        // A symlinked parent must never redirect cleanup outside the recorded roots.
        for (path, root) in [(external, volume), (backup, volume), (staging, volume), (localBackup, local.deletingLastPathComponent())] {
            let parent = path.deletingLastPathComponent().standardizedFileURL
            let relative = String(parent.path.dropFirst(root.standardizedFileURL.path.count))
            let expected = URL(fileURLWithPath: root.resolvingSymlinksInPath().path + relative).standardizedFileURL.path
            guard parent.resolvingSymlinksInPath().path == expected else {
                throw unavailable("A repair parent directory is redirected by a symbolic link.")
            }
        }
        func exists(_ url: URL) -> Bool { (try? fileManager.attributesOfItem(atPath: url.path)) != nil }
        func directory(_ url: URL) -> Bool {
            (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
        }
        let backupExists = directory(backup)
        let externalExists = directory(external)
        let localExists = directory(local)
        let shapeMatches: Bool
        switch record.phase {
        case .started, .staged:
            shapeMatches = localExists && externalExists && !exists(backup) && !exists(localBackup)
        case .backedUpExternal:
            shapeMatches = localExists && !exists(external) && backupExists && !exists(localBackup)
        case .placedNewExternal:
            shapeMatches = localExists && externalExists && backupExists && !exists(localBackup)
        case .linked, .manifestUpdated:
            let target = try? fileManager.destinationOfSymbolicLink(atPath: local.path)
            let resolved = target.map { URL(fileURLWithPath: $0, relativeTo: local.deletingLastPathComponent()).standardizedFileURL.path }
            shapeMatches = resolved == external.path && directory(localBackup) && externalExists && backupExists
        case .completed: shapeMatches = false
        }
        guard shapeMatches else { throw unavailable("The recorded phase and current copies disagree. Inspect the paths manually.") }
        let stagingParent = staging.deletingLastPathComponent()
        if exists(stagingParent) {
            guard directory(stagingParent),
                  try fileManager.contentsOfDirectory(at: stagingParent, includingPropertiesForKeys: nil)
                    .allSatisfy({ $0.lastPathComponent == name }) else {
                throw unavailable("The staging directory contains additional data outside the recorded app.")
            }
        }
        let inspector = DarwinRepairSafetyInspector(fileManager: fileManager, commandRunner: commandRunner)
        let paths = [local, external, backup, staging, localBackup]
        try inspector.assertSafeToOperate(at: paths)
        var copies: [AppCopyInfo] = []
        for path in paths where directory(path) {
            let copy = try inspector.inspectBundle(at: path)
            guard copy.signatureStatus == "Valid", let identifier = copy.bundleIdentifier, !identifier.isEmpty else {
                throw unavailable("A rollback copy has an invalid or unverifiable application identity: " + path.path)
            }
            copies.append(copy)
        }
        guard Set(copies.compactMap(\.bundleIdentifier)).count == 1 else {
            throw unavailable("Rollback copies have different bundle identifiers.")
        }
        var fingerprints: [String: String] = [:]
        let fingerprinter = OperationPathFingerprinter(fileManager: fileManager)
        for path in paths + [staging.deletingLastPathComponent(), MacBayPaths.manifestURL(on: volume)] {
            fingerprints[path.path] = try fingerprinter.fingerprint(path, recursive: true)
        }
        return RepairRollbackPlan(record: record, volumeUUID: volumeUUID, copies: copies, fingerprints: fingerprints)
    }
    private func unavailable(_ reason: String) -> MacBayError {
        .unsupportedOperation(reason + " Refresh Recovery Center and review a new preview; no rollback was started.")
    }
}
