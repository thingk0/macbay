import ArgumentParser
import MacBayKit

struct XcodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Externalize Xcode storage and purge developer caches.",
        aliases: ["xc"]
    )

    @OptionGroup var options: MutatingOptions

    @Flag(name: .customLong("clean-derived-data"), help: "Purge Xcode DerivedData build caches.")
    var cleanDerivedData: Bool = false

    @Flag(name: .customLong("clean-caches"), help: "Purge CoreSimulator and Xcode application caches.")
    var cleanCaches: Bool = false

    @Flag(name: .customLong("externalize-derived-data"), help: "Externalize DerivedData to external storage (advanced).")
    var externalizeDerivedData: Bool = false

    @Flag(name: .customLong("all"), help: "Run standard externalization and clean all Xcode caches.")
    var all: Bool = false

    @Flag(name: [.short, .customLong("force")], help: "Proceed even if Xcode is currently running.")
    var force: Bool = false

    func run() throws {
        var actions: [String] = ["externalize Xcode DeviceSupport and Archives", "delete unavailable simulators"]
        if externalizeDerivedData {
            actions.append("externalize DerivedData")
        }
        if cleanDerivedData || all {
            actions.append("clean DerivedData")
        }
        if cleanCaches || all {
            actions.append("clean simulator and Xcode caches")
        }

        let confirmMessage = "MacBay will \(actions.joined(separator: ", "))."
        try CommandSupport.confirm(
            confirmMessage,
            yes: options.yes,
            dryRun: options.dryRun
        )

        let doctorOptions = XcodeDoctorOptions(
            externalizeDeviceSupport: true,
            externalizeArchives: true,
            externalizeDerivedData: externalizeDerivedData,
            cleanDerivedData: cleanDerivedData || all,
            cleanCaches: cleanCaches || all,
            force: force
        )

        let report = try MacBayService().xcode(
            volumePath: options.volume,
            options: doctorOptions,
            dryRun: options.dryRun
        )
        try CommandSupport.printValue(report, json: options.json) { $0.xcode(report) }
    }
}
