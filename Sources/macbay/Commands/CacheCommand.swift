import ArgumentParser
import MacBayKit

struct CacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Route npm, uv, Gradle, and Hugging Face caches to external storage.",
        aliases: ["c"]
    )

    @Flag(name: .long, help: "Enable external cache routing.")
    var enable = false

    @Flag(name: .long, help: "Remove MacBay-managed cache environment settings.")
    var reset = false

    @OptionGroup var options: MutatingOptions

    func validate() throws {
        guard enable != reset else {
            throw ValidationError("Specify exactly one of --enable or --reset.")
        }
    }

    func run() throws {
        try CommandSupport.confirm(
            reset
                ? "MacBay will remove its managed cache settings from ~/.zshrc."
                : "MacBay will route developer caches to external storage and update ~/.zshrc.",
            yes: options.yes,
            dryRun: options.dryRun
        )
        let report = try MacBayService().cache(
            volumePath: options.volume,
            dryRun: options.dryRun,
            reset: reset
        )
        try CommandSupport.printValue(report, json: options.json) { $0.cache(report) }
    }
}
