import ArgumentParser
import MacBayKit

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the log of mutating MacBay operations.",
        discussion: "Every mutating command (dock, undock, move, unmove, adopt, repair, cache, purge, xcode, teardown, init, doctor --fix) appends one entry to ~/.local/state/macbay/history.jsonl on the internal disk, including failures, so the log survives detached external volumes. Entries are reference data only — they are never used by doctor verdicts or safety checks. Reversible operations carry an 'undo' hint showing the command that would reverse them. The file is rotated once it exceeds 5MB, keeping one previous generation.",
        aliases: ["hist"]
    )

    @Option(name: .long, help: "Show at most the N most recent entries.")
    var limit: Int?

    @Option(name: .long, help: "Show only entries for this command (e.g. 'dock', 'cache').")
    var command: String?

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false

    func run() throws {
        let entries = MacBayService().history(limit: limit, command: command)
        try CommandSupport.printValue(entries, json: json) { $0.history(entries) }
    }
}
