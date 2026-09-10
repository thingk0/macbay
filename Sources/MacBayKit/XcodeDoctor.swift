import Foundation

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
        let source = homeDirectory
            .appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
        let destination = MacBayPaths.xcodeRoot(on: volume)
            .appendingPathComponent("iOS DeviceSupport", isDirectory: true)

        let deviceSupport: MigrationResult?
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
                throw MacBayError.pathMissing("Xcode DeviceSupport link target does not exist: \(resolvedURL.path)")
            }

            // 2. 내부 디스크 링크 검증 (Internal volume check)
            let info = try volumeManager.diskInfoProvider.diskInfo(for: resolvedURL.path)
            let prefix = volumeManager.volumeMountPrefix.hasSuffix("/") ? volumeManager.volumeMountPrefix : volumeManager.volumeMountPrefix + "/"
            if info.isInternal || !resolvedURL.path.hasPrefix(prefix) {
                throw MacBayError.invalidVolume("Xcode DeviceSupport links to an internal volume: \(resolvedURL.path)")
            }

            // 3. 선택 볼륨 검증 (Selected volume check)
            let selectedVolumePath = volume.standardizedFileURL.path
            guard resolvedURL.path.hasPrefix(selectedVolumePath + "/") || resolvedURL.path == selectedVolumePath else {
                throw MacBayError.invalidVolume("Xcode DeviceSupport links to \(resolvedURL.path), which is on a different volume than \(selectedVolumePath)")
            }

            // 4. 외장 APFS 조건 검증 (External APFS check)
            let check = volumeManager.eligibilityCheck(for: info)
            guard check.isEligible else {
                throw MacBayError.invalidVolume("Xcode DeviceSupport volume is not eligible: \(check.reason ?? "Ineligible volume") (\(resolvedURL.path))")
            }

            // 5. 레거시 링크 인정 및 실제 대상 경로 보고
            let message = resolvedURL.path == destination.path
                ? "Xcode DeviceSupport is already externalized to \(destination.path)"
                : "Xcode DeviceSupport is already linked to legacy external path: \(resolvedURL.path)"

            let sizeBytes = (try? sizeCalculator.size(of: resolvedURL)) ?? 0
            deviceSupport = MigrationResult(
                operation: "externalize Xcode DeviceSupport",
                name: source.lastPathComponent,
                sourcePath: source.path,
                destinationPath: resolvedURL.path,
                sizeBytes: sizeBytes,
                dryRun: dryRun,
                messages: [message]
            )
        } else if fileManager.fileExists(atPath: source.path) {
            deviceSupport = try directoryMigrator.migrate(
                source: source,
                destination: destination,
                operation: "externalize Xcode DeviceSupport",
                dryRun: dryRun
            )
        } else {
            deviceSupport = nil
        }

        let simulatorCleanup = try cleanupUnavailableSimulators(dryRun: dryRun)
        return XcodeDoctorReport(deviceSupport: deviceSupport, simulatorCleanup: simulatorCleanup)
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
}
