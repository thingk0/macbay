import ArgumentParser

struct MutatingOptions: ParsableArguments {
    @Option(
        name: [.customShort("v"), .long],
        help: "External volume mount path (default: auto-detected under /Volumes)."
    )
    var volume: String?

    @Flag(
        name: [.customShort("y"), .long],
        help: "Skip confirmation prompts."
    )
    var yes = false

    @Flag(name: .long, help: "Preview actions without modifying files.")
    var dryRun = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false
}

struct StatusOptions: ParsableArguments {
    @Option(
        name: [.customShort("v"), .long],
        help: "External volume mount path (default: auto-detected under /Volumes)."
    )
    var volume: String?

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false
}

struct ScanOptions: ParsableArguments {
    @Flag(name: .long, help: "Show detailed paths and compatibility evidence (ignored when --json is specified).")
    var verbose = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false
}
