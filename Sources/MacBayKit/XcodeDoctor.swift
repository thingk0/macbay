import Foundation

public struct XcodeDoctorOptions: Sendable {
    public var externalizeDeviceSupport: Bool
    public var externalizeArchives: Bool
    public var externalizeDerivedData: Bool
    public var cleanDerivedData: Bool
    public var cleanCaches: Bool
    public var force: Bool

    public init(
        externalizeDeviceSupport: Bool = true,
        externalizeArchives: Bool = true,
        externalizeDerivedData: Bool = false,
        cleanDerivedData: Bool = false,
        cleanCaches: Bool = false,
        force: Bool = false
    ) {
        self.externalizeDeviceSupport = externalizeDeviceSupport
        self.externalizeArchives = externalizeArchives
        self.externalizeDerivedData = externalizeDerivedData
        self.cleanDerivedData = cleanDerivedData
        self.cleanCaches = cleanCaches
        self.force = force
    }
}

public struct XcodeDoctor {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let directoryMigrator: DirectoryMigrator
    private let volumeManager: VolumeManager
    private let sizeCalculator: FileSizeCalculator
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.directoryMigrator = DirectoryMigrator(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    public func run(on volume: URL, dryRun: Bool) throws -> XcodeDoctorReport {
        try run(on: volume, options: XcodeDoctorOptions(), dryRun: dryRun)
    }

    public func run(on volume: URL, options: XcodeDoctorOptions, dryRun: Bool) throws -> XcodeDoctorReport {
        if options.cleanDerivedData || options.cleanCaches || options.externalizeDerivedData || options.externalizeArchives {
            try assertXcodeNotRunning(force: options.force)
        }

        var totalFreedBytes: UInt64 = 0

        // 1. iOS DeviceSupport Externalization
        let deviceSupport: MigrationResult?
        if options.externalizeDeviceSupport {
            let source = MacBayPaths.defaultXcodeDeviceSupportURL(homeDirectory: homeDirectory)
            let destination = MacBayPaths.xcodeRoot(on: volume)
                .appendingPathComponent("iOS DeviceSupport", isDirectory: true)
            deviceSupport = try externalizeDirectory(
                source: source,
                destination: destination,
                displayName: "Xcode iOS DeviceSupport",
                on: volume,
                dryRun: dryRun
            )
        } else {
            deviceSupport = nil
        }

        // 2. Archives Externalization
        let archives: MigrationResult?
        if options.externalizeArchives {
            let source = MacBayPaths.defaultXcodeArchivesURL(homeDirectory: homeDirectory)
            let destination = MacBayPaths.xcodeArchivesRoot(on: volume)
            archives = try externalizeDirectory(
                source: source,
                destination: destination,
                displayName: "Xcode Archives",
                on: volume,
                dryRun: dryRun
            )
        } else {
            archives = nil
        }

        // 3. DerivedData Externalization (Optional)
        let derivedData: MigrationResult?
        if options.externalizeDerivedData {
            let source = MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory)
            let destination = MacBayPaths.xcodeDerivedDataRoot(on: volume)
            derivedData = try externalizeDirectory(
                source: source,
                destination: destination,
                displayName: "Xcode DerivedData",
                on: volume,
                dryRun: dryRun
            )
        } else {
            derivedData = nil
        }

        // 4. DerivedData Cleanup
        let derivedDataCleanup: CommandResultSummary?
        if options.cleanDerivedData {
            let (summary, freed) = try cleanupDerivedData(dryRun: dryRun)
            derivedDataCleanup = summary
            totalFreedBytes += freed
        } else {
            derivedDataCleanup = nil
        }

        // 5. Xcode & Simulator Caches Cleanup
        let cacheCleanup: CommandResultSummary?
        if options.cleanCaches {
            let (summary, freed) = try cleanupCaches(dryRun: dryRun)
            cacheCleanup = summary
            totalFreedBytes += freed
        } else {
            cacheCleanup = nil
        }

        // 6. Unavailable Simulators Cleanup
        let simulatorCleanup = try cleanupUnavailableSimulators(dryRun: dryRun)

        return XcodeDoctorReport(
            deviceSupport: deviceSupport,
            archives: archives,
            derivedData: derivedData,
            simulatorCleanup: simulatorCleanup,
            derivedDataCleanup: derivedDataCleanup,
            cacheCleanup: cacheCleanup,
            freedBytes: totalFreedBytes
        )
    }

    private func externalizeDirectory(
        source: URL,
        destination: URL,
        displayName: String,
        on volume: URL,
        dryRun: Bool
    ) throws -> MigrationResult? {
        if let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: source.path) {
            let resolvedURL: URL
            if linkDestination.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: linkDestination).standardizedFileURL
            } else {
                resolvedURL = source.deletingLastPathComponent()
                    .appendingPathComponent(linkDestination)
                    .standardizedFileURL
            }

            // 1. 존재 여부 (Existence check)
            guard fileManager.fileExists(atPath: resolvedURL.path) else {
                throw MacBayError.pathMissing("\(displayName) link target does not exist: \(resolvedURL.path)")
            }

            // 2. 내부 디스크 링크 검증 (Internal volume check)
            let info = try volumeManager.diskInfoProvider.diskInfo(for: resolvedURL.path)
            let prefix = volumeManager.volumeMountPrefix.hasSuffix("/") ? volumeManager.volumeMountPrefix : volumeManager.volumeMountPrefix + "/"
            if info.isInternal || !resolvedURL.path.hasPrefix(prefix) {
                throw MacBayError.invalidVolume("\(displayName) links to an internal volume: \(resolvedURL.path)")
            }

            // 3. 선택 볼륨 검증 (Selected volume check)
            let selectedVolumePath = volume.standardizedFileURL.path
            guard resolvedURL.path.hasPrefix(selectedVolumePath + "/") || resolvedURL.path == selectedVolumePath else {
                throw MacBayError.invalidVolume("\(displayName) links to \(resolvedURL.path), which is on a different volume than \(selectedVolumePath)")
            }

            // 4. 외장 APFS 조건 검증 (External APFS check)
            let check = volumeManager.eligibilityCheck(for: info)
            guard check.isEligible else {
                throw MacBayError.invalidVolume("\(displayName) volume is not eligible: \(check.reason ?? "Ineligible volume") (\(resolvedURL.path))")
            }

            // 5. 레거시 링크 인정 및 실제 대상 경로 보고
            let message = resolvedURL.path == destination.path
                ? "\(displayName) is already externalized to \(destination.path)"
                : "\(displayName) is already linked to legacy external path: \(resolvedURL.path)"

            let sizeBytes = (try? sizeCalculator.size(of: resolvedURL)) ?? 0
            return MigrationResult(
                operation: "externalize \(displayName)",
                name: source.lastPathComponent,
                sourcePath: source.path,
                destinationPath: resolvedURL.path,
                sizeBytes: sizeBytes,
                dryRun: dryRun,
                messages: [message]
            )
        } else if fileManager.fileExists(atPath: source.path) {
            return try directoryMigrator.migrate(
                source: source,
                destination: destination,
                operation: "externalize \(displayName)",
                dryRun: dryRun
            )
        } else {
            return nil
        }
    }

    private func cleanupDerivedData(dryRun: Bool) throws -> (CommandResultSummary, UInt64) {
        let derivedDataURL = MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: derivedDataURL.path) else {
            return (
                CommandResultSummary(
                    command: "clean DerivedData",
                    succeeded: true,
                    output: "DerivedData is empty or does not exist"
                ),
                0
            )
        }

        let resolvedURL: URL
        if let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: derivedDataURL.path) {
            resolvedURL = linkDestination.hasPrefix("/")
                ? URL(fileURLWithPath: linkDestination)
                : derivedDataURL.deletingLastPathComponent().appendingPathComponent(linkDestination)
        } else {
            resolvedURL = derivedDataURL
        }

        let sizeBytes = (try? sizeCalculator.size(of: resolvedURL)) ?? 0
        let formattedSize = OutputFormatter.humanBytes(sizeBytes)

        if dryRun {
            return (
                CommandResultSummary(
                    command: "clean DerivedData",
                    succeeded: true,
                    output: "Dry run: would clean \(formattedSize) from \(derivedDataURL.path)"
                ),
                sizeBytes
            )
        }

        let items = (try? fileManager.contentsOfDirectory(at: resolvedURL, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            try? fileManager.removeItem(at: item)
        }

        return (
            CommandResultSummary(
                command: "clean DerivedData",
                succeeded: true,
                output: "Cleaned \(formattedSize) from \(derivedDataURL.path)"
            ),
            sizeBytes
        )
    }

    private func cleanupCaches(dryRun: Bool) throws -> (CommandResultSummary, UInt64) {
        let coreSimCacheURL = MacBayPaths.defaultCoreSimulatorCachesURL(homeDirectory: homeDirectory)
        let xcodeCacheURL = MacBayPaths.defaultXcodeCachesURL(homeDirectory: homeDirectory)

        var totalBytes: UInt64 = 0
        var cleanedDetails: [String] = []

        let targets = [
            ("CoreSimulator Caches", coreSimCacheURL),
            ("Xcode App Caches", xcodeCacheURL)
        ]

        for (name, url) in targets {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let sizeBytes = (try? sizeCalculator.size(of: url)) ?? 0
            if sizeBytes > 0 {
                totalBytes += sizeBytes
                cleanedDetails.append("\(name): \(OutputFormatter.humanBytes(sizeBytes))")
            }

            if !dryRun {
                let items = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    try? fileManager.removeItem(at: item)
                }
            }
        }

        let formattedTotal = OutputFormatter.humanBytes(totalBytes)
        if totalBytes == 0 {
            return (
                CommandResultSummary(
                    command: "clean Xcode caches",
                    succeeded: true,
                    output: "No cache files found to clean"
                ),
                0
            )
        }

        let detailsString = cleanedDetails.joined(separator: ", ")
        let output = dryRun
            ? "Dry run: would clean \(formattedTotal) (\(detailsString))"
            : "Cleaned \(formattedTotal) (\(detailsString))"

        return (
            CommandResultSummary(
                command: "clean Xcode caches",
                succeeded: true,
                output: output
            ),
            totalBytes
        )
    }

    private func cleanupUnavailableSimulators(dryRun: Bool) throws -> CommandResultSummary {
        let command = "/usr/bin/xcrun simctl delete unavailable"
        if dryRun {
            return CommandResultSummary(
                command: command,
                succeeded: true,
                output: "Dry run: simulator state was not changed"
            )
        }

        do {
            let result = try commandRunner.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "delete", "unavailable"]
            )
            let output = [result.standardOutput, result.standardError]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResultSummary(command: command, succeeded: result.status == 0, output: output)
        } catch {
            return CommandResultSummary(command: command, succeeded: false, output: error.localizedDescription)
        }
    }

    private func assertXcodeNotRunning(force: Bool) throws {
        guard !force else { return }
        let result = try? commandRunner.run("/usr/bin/pgrep", arguments: ["-x", "Xcode"])
        if let result, result.status == 0 {
            throw MacBayError.unsupportedOperation(
                "Xcode is currently running. Please quit Xcode before modifying its storage or caches, or pass --force to proceed anyway."
            )
        }
    }
}
