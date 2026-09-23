import Foundation

public struct LocalAppRecoveryReport: Codable, Equatable, Sendable {
    public let appName: String
    public let sourcePath: String
    public let candidatePath: String
    public let externalPath: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let version: String?
    public let sizeBytes: UInt64
    public let dryRun: Bool
    public let messages: [String]
}

public struct LocalAppRecoveryManager {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunner
    private let volumeManager: VolumeManager
    private let manifestStore: ManifestStore
    private let processInspector: ProcessInspector
    private let sizeCalculator: FileSizeCalculator
    private let spaceEstimator: SpaceEstimator
    private let operationLock: any VolumeOperationLocking
    private let volumeMountPrefix: String
    private let applicationsDirectory: URL

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        volumeManager: VolumeManager? = nil,
        operationLock: any VolumeOperationLocking = VolumeOperationLock(),
        volumeMountPrefix: String = "/Volumes",
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.volumeManager = volumeManager ?? VolumeManager(
            fileManager: fileManager,
            diskInfoProvider: SystemDiskInfoProvider(commandRunner: commandRunner)
        )
        self.manifestStore = ManifestStore(fileManager: fileManager)
        self.processInspector = ProcessInspector(commandRunner: commandRunner, fileManager: fileManager)
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.spaceEstimator = SpaceEstimator(diskInfoProvider: self.volumeManager.diskInfoProvider)
        self.operationLock = operationLock
        self.volumeMountPrefix = URL(fileURLWithPath: volumeMountPrefix).standardizedFileURL.path
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
    }

    public func recover(
        appName: String,
        from candidatePath: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        dryRun: Bool
    ) throws -> LocalAppRecoveryReport {
        let cleanName = appName.hasSuffix(".app")
            ? URL(fileURLWithPath: appName).lastPathComponent
            : "\(URL(fileURLWithPath: appName).lastPathComponent).app"
        let local = applicationsDirectory.appendingPathComponent(cleanName, isDirectory: true).standardizedFileURL
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL
        guard local.deletingLastPathComponent().standardizedFileURL.path == applicationsDirectory.path else {
            throw MacBayError.unsupportedOperation("Local recovery is limited to direct children of /Applications.")
        }
        guard !expectedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expectedTeamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacBayError.unsupportedOperation("Expected bundle and team identifiers are required for local recovery.")
        }
        guard candidate.pathExtension.lowercased() == "app",
              candidate.lastPathComponent == cleanName,
              fileManager.fileExists(atPath: candidate.path),
              !isSymbolicLink(candidate) else {
            throw MacBayError.invalidApplication("Recovery source must be an existing, real \(cleanName) bundle.")
        }

        let externalPath: String
        let existingLocal: Bool
        if let target = symlinkTarget(local) {
            externalPath = target.path
            existingLocal = false
        } else if fileManager.fileExists(atPath: local.path) {
            externalPath = try manifestExternalPath(for: local.path, appName: cleanName)
            existingLocal = true
        } else {
            throw MacBayError.unsupportedOperation("Recovery requires the original MacBay link or a previously restored local app.")
        }

        let volumePath = try volumePath(forMacBayApplication: externalPath, appName: cleanName)
        let volume = try volumeManager.resolveExternalVolume(path: volumePath)
        let volumeURL = URL(fileURLWithPath: volume.path)
        let diskInfo = try volumeManager.diskInfoProvider.diskInfo(for: volume.path)
        let savedVolume = DefaultVolume(
            path: volume.path,
            name: diskInfo.volumeName,
            uuid: diskInfo.volumeUUID,
            savedAt: macBayTimestamp()
        )
        switch volumeManager.availability(of: savedVolume) {
        case .mounted:
            break
        case .notMounted:
            throw MacBayError.invalidVolume("Original MacBay volume is not mounted: \(volume.path)")
        case let .ineligible(path, reason):
            throw MacBayError.invalidVolume("Original MacBay volume at \(path) is not eligible: \(reason)")
        }
        guard !fileManager.fileExists(atPath: externalPath) else {
            throw MacBayError.unsupportedOperation("The recorded external application exists; local recovery is only for a missing target.")
        }
        let manifest = try manifestStore.load(on: volumeURL)
        guard manifest.items.contains(where: {
            $0.kind == .application &&
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == local.path &&
            URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path == externalPath
        }) else {
            throw MacBayError.manifestFailed(
                path: MacBayPaths.manifestURL(on: volumeURL).path,
                details: "No matching MacBay application record exists for the broken link."
            )
        }

        let candidateMetadata = try verifyBundle(
            at: candidate,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
        try processInspector.assertSafeToMove(path: candidate)
        if existingLocal {
            _ = try verifyBundle(
                at: local,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier
            )
            try processInspector.assertSafeToMove(path: local)
        }

        let size = try sizeCalculator.size(of: candidate)
        let internalVolume = URL(fileURLWithPath: "/")
        let estimate = spaceEstimator.estimate(copyBytes: size, destinationVolume: internalVolume)
        guard estimate.isVerifiable else {
            throw MacBayError.spaceCheckFailed(path: internalVolume.path, details: "Unable to verify free space for local recovery.")
        }
        if estimate.shortfallBytes > 0 {
            throw MacBayError.insufficientSpace(
                path: internalVolume.path,
                neededBytes: size,
                availableBytes: estimate.destinationAvailableBytes ?? 0
            )
        }

        let report = LocalAppRecoveryReport(
            appName: cleanName,
            sourcePath: local.path,
            candidatePath: candidate.path,
            externalPath: externalPath,
            bundleIdentifier: candidateMetadata.bundleIdentifier,
            teamIdentifier: candidateMetadata.teamIdentifier,
            version: candidateMetadata.version,
            sizeBytes: size,
            dryRun: dryRun,
            messages: existingLocal
                ? ["A verified local app is already installed; execution will only remove its stale MacBay record."]
                : ["A verified copy will be installed in /Applications. The source bundle and staged installer will be preserved."]
        )
        guard !dryRun else { return report }

        return try operationLock.withVolumeLock(on: volumeURL) {
            if !existingLocal {
                guard symlinkTarget(local)?.path == externalPath,
                      !fileManager.fileExists(atPath: externalPath) else {
                    throw MacBayError.unsupportedOperation("The original link or external target changed during recovery.")
                }
                try spaceEstimator.requireSufficientSpace(copyBytes: size, destinationVolume: internalVolume)
                let staging = local.deletingLastPathComponent()
                    .appendingPathComponent(".\(cleanName).macbay-recover-\(UUID().uuidString)", isDirectory: true)
                do {
                    let copy = try commandRunner.run("/usr/bin/ditto", arguments: [candidate.path, staging.path])
                    guard copy.status == 0 else {
                        throw MacBayError.commandFailed(
                            executable: "/usr/bin/ditto",
                            status: copy.status,
                            details: copy.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    _ = try verifyBundle(
                        at: staging,
                        expectedBundleIdentifier: expectedBundleIdentifier,
                        expectedTeamIdentifier: expectedTeamIdentifier
                    )
                    try fileManager.removeItem(at: local)
                    do {
                        try fileManager.moveItemPreservingPermissions(at: staging, to: local)
                    } catch {
                        try? fileManager.createSymbolicLink(atPath: local.path, withDestinationPath: externalPath)
                        throw error
                    }
                } catch {
                    try? fileManager.removeItemMakingWritable(at: staging)
                    throw error
                }
            }

            try manifestStore.updating(on: volumeURL) { current in
                guard let index = current.items.firstIndex(where: {
                    $0.kind == .application &&
                    URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == local.path &&
                    URL(fileURLWithPath: $0.externalPath).standardizedFileURL.path == externalPath
                }) else {
                    throw MacBayError.manifestFailed(
                        path: MacBayPaths.manifestURL(on: volumeURL).path,
                        details: "The matching MacBay record changed during recovery; the local app was preserved."
                    )
                }
                current.items.remove(at: index)
            }
            _ = try? commandRunner.run(
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                arguments: ["-f", local.path]
            )
            return LocalAppRecoveryReport(
                appName: cleanName,
                sourcePath: local.path,
                candidatePath: candidate.path,
                externalPath: externalPath,
                bundleIdentifier: candidateMetadata.bundleIdentifier,
                teamIdentifier: candidateMetadata.teamIdentifier,
                version: candidateMetadata.version,
                sizeBytes: size,
                dryRun: false,
                messages: [
                    "Installed and verified in /Applications.",
                    "Removed the stale MacBay record; the external target and recovery source were left untouched."
                ]
            )
        }
    }

    private func manifestExternalPath(for sourcePath: String, appName: String) throws -> String {
        let volumes = volumeManager.diagnosticVolumes().volumes
        let matches = try volumes.flatMap { info -> [String] in
            try manifestStore.load(on: URL(fileURLWithPath: info.mountPoint)).items.compactMap { item in
                guard item.kind == .application,
                      URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path == sourcePath else { return nil }
                return item.externalPath
            }
        }
        guard matches.count == 1, matches[0].hasSuffix("/MacBay/Applications/\(appName)") else {
            throw MacBayError.unsupportedOperation("Expected exactly one matching MacBay record for the local app.")
        }
        return matches[0]
    }

    private func volumePath(forMacBayApplication path: String, appName: String) throws -> String {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let mountComponents = URL(fileURLWithPath: volumeMountPrefix).standardizedFileURL.pathComponents
        let suffix = ["MacBay", "Applications", appName]
        guard components.count == mountComponents.count + 1 + suffix.count,
              Array(components.prefix(mountComponents.count)) == mountComponents,
              Array(components.suffix(suffix.count)) == suffix else {
            throw MacBayError.unsupportedOperation("Recorded target is not under the standard external MacBay Applications directory.")
        }
        let volumeMountComponents = Array(components.prefix(mountComponents.count + 1))
        return URL(fileURLWithPath: NSString.path(withComponents: volumeMountComponents)).path
    }

    private func verifyBundle(
        at url: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> (bundleIdentifier: String, teamIdentifier: String, version: String?) {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              bundleIdentifier == expectedBundleIdentifier else {
            throw MacBayError.invalidApplication("Recovery bundle identifier does not match \(expectedBundleIdentifier).")
        }
        let signature = try commandRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", url.path])
        guard signature.status == 0 else {
            throw MacBayError.signatureVerificationFailed(
                path: url.path,
                details: signature.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let details = try commandRunner.run("/usr/bin/codesign", arguments: ["-dv", "--verbose=2", url.path])
        let combined = details.standardOutput + "\n" + details.standardError
        guard details.status == 0,
              let teamLine = combined.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("TeamIdentifier=") }),
              String(teamLine.dropFirst("TeamIdentifier=".count)) == expectedTeamIdentifier else {
            throw MacBayError.signatureVerificationFailed(
                path: url.path,
                details: "Signed TeamIdentifier does not match expected \(expectedTeamIdentifier)."
            )
        }
        return (bundleIdentifier, expectedTeamIdentifier, info["CFBundleShortVersionString"] as? String)
    }

    private func symlinkTarget(_ url: URL) -> URL? {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: raw, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
