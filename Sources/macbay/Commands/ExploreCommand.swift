import ArgumentParser
import Foundation
import MacBayKit

struct ExploreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "Scan a directory by disk usage and compare with the previous scan.",
        discussion: "Lists immediate children by allocated size with logical size, previous-scan deltas, and the move action each entry supports. Allocated size is an upper bound: APFS clones, shared blocks, and snapshots can make the actual freed space smaller.",
        aliases: ["ex"]
    )

    @Argument(help: "Directory to explore, such as '~/Library/Application Support'.")
    var path: String

    @Option(name: [.customShort("n"), .long], help: "Maximum entries to display.")
    var limit: Int = 30

    @Flag(name: .long, help: "Rescan and update the stored record for this directory.")
    var rescan: Bool = false

    @Flag(name: .long, help: "Preview the move for one entry without changing files.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Preview the move for this entry path (implies --dry-run).")
    var moveEntry: String?

    @Flag(name: .long, help: "Watch this directory with FSEvents and refresh changed entries automatically.")
    var watch: Bool = false

    @OptionGroup var options: ExploreVolumeOptions

    func run() throws {
        let service = MacBayService()
        let report = try service.explore(path: path)
        _ = rescan
        if let moveEntry {
            let preview = try service.exploreMovePreview(path: moveEntry, volumePath: options.volume)
            try CommandSupport.printValue(preview, json: options.json) { $0.migration(preview) }
            return
        }
        try CommandSupport.printValue(report, json: options.json) { $0.explore(report, limit: limit) }
        if watch {
            try watchLoop(service: service, root: report.rootPath)
        }
    }

    private func watchLoop(service: MacBayService, root: String) throws {
        print("Watching \(root) for changes (Ctrl-C to stop)…")
        let monitor = ExplorerChangeMonitor(watchedRoot: root)
        let semaphore = DispatchSemaphore(value: 0)
        let state = WatchState()
        let subscription = monitor.subscribe { event in
            guard !state.stopped else { return }
            guard let result = service.refreshExplorer(
                root: root,
                changedPaths: event.changedPaths,
                droppedEvents: event.droppedEvents
            ) else { return }
            let formatter = CommandSupport.formatter(json: options.json)
            if options.json {
                print((try? formatter.json(result.report)) ?? "")
            } else {
                print(formatter.explore(result.report, limit: limit))
                if result.fullRescan {
                    print("(full rescan: change events were coalesced or dropped)")
                } else if !result.refreshedPaths.isEmpty {
                    print("Refreshed: \(result.refreshedPaths.joined(separator: ", "))")
                }
            }
        }
        _ = subscription
        WatchSignalHandler.install(semaphore: semaphore)
        semaphore.wait()
        state.stopped = true
        monitor.stop()
    }

    private final class WatchState: @unchecked Sendable {
        var stopped = false
    }

    private enum WatchSignalHandler {
        private static var semaphore: DispatchSemaphore?

        static func install(semaphore: DispatchSemaphore) {
            WatchSignalHandler.semaphore = semaphore
            signal(SIGINT, WatchSignalHandler.handle)
            signal(SIGTERM, WatchSignalHandler.handle)
        }

        private static let handle: @convention(c) (Int32) -> Void = { _ in
            WatchSignalHandler.semaphore?.signal()
        }
    }
}

struct ExploreVolumeOptions: ParsableArguments {
    @Option(
        name: [.customShort("v"), .long],
        help: "External volume mount path (default: the volume saved by 'mb init', otherwise auto-detected under /Volumes)."
    )
    var volume: String?

    @Flag(name: .long, help: "Output machine-readable JSON.")
    var json = false
}
