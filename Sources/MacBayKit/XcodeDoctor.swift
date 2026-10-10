import Foundation

public struct XcodeDoctorOptions: Equatable, Sendable {
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

        // Validate all selected actions before any mutation. Runtime failures still retain
        // successful action results instead of discarding an already partially completed run.
        if !dryRun { _ = try run(on: volume, options: options, dryRun: true) }
        var failures: [XcodeActionFailure] = []
        func externalize(_ enabled: Bool, source: URL, destination: URL, name: String) throws -> MigrationResult? {
            guard enabled else { return nil }
            do {
                return try externalizeDirectory(source: source, destination: destination,
                                                displayName: name, on: volume, dryRun: dryRun)
            } catch {
                if dryRun { throw error }
                failures.append(XcodeActionFailure(action: "externalize " + name, reason: error.localizedDescription))
                return nil
            }
        }
        let deviceSupport = try externalize(options.externalizeDeviceSupport,
            source: MacBayPaths.defaultXcodeDeviceSupportURL(homeDirectory: homeDirectory),
            destination: MacBayPaths.xcodeRoot(on: volume).appendingPathComponent("iOS DeviceSupport", isDirectory: true),
            name: "Xcode iOS DeviceSupport")
        let archives = try externalize(options.externalizeArchives,
            source: MacBayPaths.defaultXcodeArchivesURL(homeDirectory: homeDirectory),
            destination: MacBayPaths.xcodeArchivesRoot(on: volume), name: "Xcode Archives")
        let derivedData = try externalize(options.externalizeDerivedData,
            source: MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory),
            destination: MacBayPaths.xcodeDerivedDataRoot(on: volume), name: "Xcode DerivedData")
        let derivedDataCleanup = options.cleanDerivedData ? try cleanupDerivedData(dryRun: dryRun) : nil
        let cacheCleanup = options.cleanCaches ? try cleanupCaches(dryRun: dryRun) : nil
        let simulatorCleanup = try cleanupUnavailableSimulators(dryRun: dryRun)
        return XcodeDoctorReport(
            deviceSupport: deviceSupport, archives: archives, derivedData: derivedData,
            simulatorCleanup: simulatorCleanup, derivedDataCleanup: derivedDataCleanup?.0,
            cacheCleanup: cacheCleanup?.0, freedBytes: (derivedDataCleanup?.1 ?? 0) + (cacheCleanup?.1 ?? 0),
            failedActions: failures
        )
    }

    public func isXcodeRunning() throws -> Bool {
        let result = try commandRunner.run("/usr/bin/pgrep", arguments: ["-x", "Xcode"])
        guard result.status == 0 || result.status == 1 else {
            throw MacBayError.commandFailed(executable: "/usr/bin/pgrep", status: result.status,
                                            details: "Could not check whether Xcode is running")
        }
        return result.status == 0
    }

    public func makePlan(on volume: URL, options: XcodeDoctorOptions) throws -> XcodeStoragePlan {
        let running = try isXcodeRunning()
        let report = try run(on: volume, options: options, dryRun: true)
        let info = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        let migrations = [report.deviceSupport, report.archives, report.derivedData].compactMap { $0 }
        let required = migrations.filter { (try? fileManager.destinationOfSymbolicLink(atPath: $0.sourcePath)) == nil }
            .reduce(UInt64(0)) { $0 + $1.sizeBytes }
        if required > 0 {
            try SpaceEstimator(diskInfoProvider: volumeManager.diskInfoProvider)
                .requireSufficientSpace(copyBytes: required, destinationVolume: volume)
        }
        let fingerprinter = XcodePathFingerprinter(fileManager: fileManager)
        var fingerprints: [String: String] = [:]
        func capture(_ url: URL, recursive: Bool = true) throws {
            if recursive || fingerprints[url.path] == nil {
                fingerprints[url.path] = try fingerprinter.fingerprint(url, recursive: recursive)
            }
            let resolved = url.resolvingSymlinksInPath()
            if resolved.path != url.path && (recursive || fingerprints[resolved.path] == nil) {
                fingerprints[resolved.path] = try fingerprinter.fingerprint(resolved, recursive: recursive)
            }
        }
        var sources: [URL] = []
        if options.externalizeDeviceSupport { sources.append(MacBayPaths.defaultXcodeDeviceSupportURL(homeDirectory: homeDirectory)) }
        if options.externalizeArchives { sources.append(MacBayPaths.defaultXcodeArchivesURL(homeDirectory: homeDirectory)) }
        if options.externalizeDerivedData || options.cleanDerivedData { sources.append(MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory)) }
        if options.cleanCaches {
            sources += [MacBayPaths.defaultCoreSimulatorCachesURL(homeDirectory: homeDirectory),
                        MacBayPaths.defaultXcodeCachesURL(homeDirectory: homeDirectory)]
        }
        for source in sources { try capture(source) }
        try capture(volume, recursive: false)
        for migration in migrations {
            var destination = URL(fileURLWithPath: migration.destinationPath)
            while destination.path.hasPrefix(volume.path + "/") {
                try capture(destination, recursive: false)
                destination.deleteLastPathComponent()
            }
        }
        return XcodeStoragePlan(volumePath: volume.path, volumeUUID: info.volumeUUID,
                                availableBytes: info.availableBytes, requiredBytes: required,
                                options: options, report: report, xcodeRunning: running,
                                unavailableSimulatorIDs: try unavailableSimulatorIDs(), fingerprints: fingerprints)
    }

    private func unavailableSimulatorIDs() throws -> [String] {
        let result = try commandRunner.run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "--json"])
        guard result.status == 0 else {
            throw MacBayError.commandFailed(executable: "/usr/bin/xcrun", status: result.status, details: result.standardError)
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else {
            throw MacBayError.unsupportedOperation("Could not preview unavailable simulators. Check Xcode command-line tools and retry.")
        }
        var ids = Set<String>()
        for device in devices.values.flatMap({ $0 }) {
            guard let available = device["isAvailable"] as? Bool,
                  let id = device["udid"] as? String, !id.isEmpty else {
                throw MacBayError.unsupportedOperation("Could not identify simulator cleanup targets. Review a fresh preview after checking Xcode command-line tools.")
            }
            if !available { ids.insert(id) }
        }
        return ids.sorted()
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
            let mountPrefix = URL(fileURLWithPath: volumeManager.volumeMountPrefix).standardizedFileURL.path
            let prefix = mountPrefix.hasSuffix("/") ? mountPrefix : mountPrefix + "/"
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
        try cleanupDirectories(command: "clean DerivedData",
            targets: [("DerivedData", MacBayPaths.defaultXcodeDerivedDataURL(homeDirectory: homeDirectory))], dryRun: dryRun)
    }

    private func cleanupCaches(dryRun: Bool) throws -> (CommandResultSummary, UInt64) {
        try cleanupDirectories(command: "clean Xcode caches", targets: [
            ("CoreSimulator Caches", MacBayPaths.defaultCoreSimulatorCachesURL(homeDirectory: homeDirectory)),
            ("Xcode App Caches", MacBayPaths.defaultXcodeCachesURL(homeDirectory: homeDirectory))
        ], dryRun: dryRun)
    }

    private func cleanupDirectories(command: String, targets: [(String, URL)], dryRun: Bool) throws -> (CommandResultSummary, UInt64) {
        var bytes: UInt64 = 0
        var details: [String] = []
        var succeeded = true
        for (name, source) in targets {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let url = source.resolvingSymlinksInPath()
            do {
                let items = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in items {
                    let size = try sizeCalculator.size(of: item)
                    if dryRun {
                        bytes += size
                    } else {
                        do {
                            try fileManager.removeItem(at: item)
                            bytes += size
                        } catch {
                            succeeded = false
                            details.append("Failed: \(item.path): \(error.localizedDescription)")
                        }
                    }
                }
                details.append("\(name): \(source.path)")
            } catch {
                if dryRun { throw error }
                succeeded = false
                details.append("Failed: \(source.path): \(error.localizedDescription)")
            }
        }
        let description = dryRun ? "Dry run: would clean" : "Cleaned"
        let output = "\(description) \(OutputFormatter.humanBytes(bytes))" + (details.isEmpty ? " (no cache files found)" : "\n" + details.joined(separator: "\n"))
        return (CommandResultSummary(command: command, succeeded: succeeded, output: output), bytes)
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
        if try isXcodeRunning() {
            throw MacBayError.unsupportedOperation(
                "Xcode is currently running. Please quit Xcode before modifying its storage or caches, or pass --force to proceed anyway."
            )
        }
    }
}
