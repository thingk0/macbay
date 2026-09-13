import Foundation

/// The restore `mb undo` runs to reverse the operation it picked.
public enum UndoOperation: String, Codable, Equatable, Sendable {
    case undock
    case unmove
}

/// The newest undoable history entry and the command that reverses it.
public struct UndoPlan: Codable, Equatable, Sendable {
    public let entry: HistoryEntry
    public let operation: UndoOperation
    /// App name for an undock, absolute directory path for an unmove.
    public let target: String
    /// The reversing command, shell-quoted exactly as a user could run it.
    public let command: String

    public init(entry: HistoryEntry, operation: UndoOperation, target: String) {
        self.entry = entry
        self.operation = operation
        self.target = target
        self.command = "mb \(operation.rawValue) \(ShellEnvironmentWriter.shellQuoted(target))"
    }
}

public struct UndoReport: Codable, Equatable, Sendable {
    public let entry: HistoryEntry
    public let command: String
    public let result: MigrationResult
    public let dryRun: Bool

    public init(entry: HistoryEntry, command: String, result: MigrationResult, dryRun: Bool) {
        self.entry = entry
        self.command = command
        self.result = result
        self.dryRun = dryRun
    }
}

/// Decides what `mb undo` may reverse. Only the newest successful history entry
/// is considered — failed attempts changed nothing and are skipped — and only a
/// `dock` or a `move` can be undone. Anything else is refused with the reason
/// instead of guessed at, so `mb undo` never reaches past a newer operation.
public enum UndoPlanner {
    public static func plan(from entries: [HistoryEntry]) throws -> UndoPlan {
        guard let entry = entries.first(where: { $0.outcome != .failure }) else {
            throw MacBayError.unsupportedOperation(
                "Nothing to undo: mb history has no successful operations."
            )
        }
        let label = "\(entry.command) \(entry.subject) (\(entry.timestamp))"
        guard entry.outcome == .success else {
            throw MacBayError.unsupportedOperation(
                "Cannot undo the last operation, \(label): it only partly succeeded. Review it with 'mb history'."
            )
        }
        switch entry.command {
        case "dock":
            return UndoPlan(entry: entry, operation: .undock, target: entry.subject)
        case "move":
            return UndoPlan(entry: entry, operation: .unmove, target: entry.subject)
        default:
            throw MacBayError.unsupportedOperation(
                "Cannot undo the last operation, \(label): \(refusalReason(for: entry))"
            )
        }
    }

    static func refusalReason(for entry: HistoryEntry) -> String {
        switch entry.command {
        case "undo":
            return "it was already an undo, and mb undo never reverses an undo."
        case "undock", "unmove":
            if let hint = entry.undo {
                return "it already restored data to the internal disk. To apply it again, run: \(hint)"
            }
            return "it already restored data to the internal disk."
        case "adopt":
            return "the app was already on external storage before it was adopted, so there is nothing to move back."
        case "cache --enable":
            return "cache routing moved caches to the external drive, and 'mb cache --reset' only removes the shell settings."
        case "cache --reset":
            return "run 'mb cache --enable' to route caches again."
        case "purge":
            return "purged caches were deleted and cannot be restored."
        case "xcode":
            return "Xcode cleanup deletes data that cannot be restored."
        case "teardown":
            return "teardown restored every managed item; dock or move items again individually."
        case "doctor --fix":
            return "link repairs made by 'mb doctor --fix' are not reversed automatically."
        default:
            if entry.command.hasPrefix("repair") {
                return "completed repairs are not reversed automatically; 'mb repair --rollback' only applies to an interrupted repair."
            }
            if entry.command.hasPrefix("init") {
                return "configuration changes are not reversed automatically; run 'mb init' again."
            }
            return "'\(entry.command)' cannot be undone automatically."
        }
    }
}
