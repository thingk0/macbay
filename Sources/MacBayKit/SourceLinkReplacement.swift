import Foundation

/// Installing the link commits the copy. Removing the old tree is a separate,
/// destructive step: a partially removed backup must never replace the live copy.
struct SourceLinkReplacement {
    let source: URL
    let destination: URL
    let backup: URL
    private let fileManager: FileManager

    init(source: URL, destination: URL, fileManager: FileManager) {
        self.source = source
        self.destination = destination
        self.fileManager = fileManager
        backup = source.deletingLastPathComponent().appendingPathComponent(
            ".\(source.lastPathComponent).macbay-\(UUID().uuidString)"
        )
    }

    func install() throws {
        try fileManager.moveItemPreservingPermissions(at: source, to: backup)
        do {
            try fileManager.createSymbolicLink(atPath: source.path, withDestinationPath: destination.path)
        } catch {
            let linkError = error
            // Do not overwrite a path another process created during the swap.
            guard !fileManager.fileExists(atPath: source.path),
                  (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) == nil else {
                throw recoveryError("The original path changed before its link could be installed. \(linkError.localizedDescription)")
            }
            do {
                try fileManager.moveItemPreservingPermissions(at: backup, to: source)
            } catch {
                throw recoveryError("The original path could not be restored. \(error.localizedDescription)")
            }
            // The untouched original has been restored successfully.
            try? fileManager.removeItemMakingWritable(at: destination)
            throw linkError
        }
    }

    func removeBackup() throws {
        do {
            try fileManager.removeItemMakingWritable(at: backup)
        } catch {
            throw MacBayError.unsupportedOperation(
                "The original path at \(source.path) links to the complete copy at \(destination.path), "
                + "but the remaining backup at \(backup.path) could not be removed. "
                + "The backup may be incomplete; keep the complete destination and inspect the backup before removing it. "
                + error.localizedDescription
            )
        }
    }

    private func recoveryError(_ reason: String) -> MacBayError {
        .unsupportedOperation("\(reason) Data copies are preserved at \(backup.path) and \(destination.path). "
            + "Inspect these copies before restoring the original path at \(source.path).")
    }
}
