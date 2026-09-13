import ArgumentParser

struct MutatingOptions: ParsableArguments {
    @Option(
        name: [.customShort("v"), .long],
        help: "External volume mount path (default: the volume saved by 'mb init', otherwise auto-detected under /Volumes)."
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
        help: "External volume mount path (default: the volume saved by 'mb init', otherwise auto-detected under /Volumes)."
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

struct DoctorOptions: ParsableArguments {
    @Option(
        name: [.customShort("v"), .long],
        help: "External volume mount path to inspect in addition to the mounted volumes under /Volumes."
    )
    var volume: String?

    @Flag(
        name: .long,
        help: "Automatically repair unambiguous findings (missing/broken links whose recorded copy exists)."
    )
    var fix = false

    @Flag(
        name: [.customShort("y"), .long],
        help: "Skip confirmation prompts (only relevant with --fix)."
    )
    var yes = false

    @Flag(name: .long, help: "Preview repairs without modifying files (only relevant with --fix).")
    var dryRun = false

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false
}
