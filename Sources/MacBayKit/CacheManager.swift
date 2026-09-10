import Foundation

public struct CacheManager {
    private struct Target {
        let name: String
        let internalURL: URL
        let externalDirectoryName: String
        let environmentVariable: String
    }

    private static let beginMarker = "# >>> macbay cache >>>"
    private static let endMarker = "# <<< macbay cache <<<"

    private let fileManager: FileManager
    private let directoryMigrator: DirectoryMigrator
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryMigrator = DirectoryMigrator(
            fileManager: fileManager,
            commandRunner: commandRunner
        )
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    public func enable(on volume: URL, dryRun: Bool) throws -> CacheReport {
        let home = homeDirectory
        let targets = Self.targets(homeDirectory: home)
        let externalRoot = MacBayPaths.cachesRoot(on: volume)
        var migrations: [MigrationResult] = []

        for target in targets {
            let destination = externalRoot.appendingPathComponent(target.externalDirectoryName, isDirectory: true)
            let migration: MigrationResult
            if isSymbolicLink(target.internalURL) {
                migration = MigrationResult(
                    operation: "configure cache",
                    name: target.name,
                    sourcePath: target.internalURL.path,
                    destinationPath: destination.path,
                    sizeBytes: 0,
                    dryRun: dryRun,
                    messages: ["Internal cache is already a symbolic link"]
                )
            } else if fileManager.fileExists(atPath: target.internalURL.path) {
                migration = try directoryMigrator.migrate(
                    source: target.internalURL,
                    destination: destination,
                    operation: "externalize cache",
                    dryRun: dryRun
                )
            } else {
                if !dryRun {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                migration = MigrationResult(
                    operation: "configure cache",
                    name: target.name,
                    sourcePath: target.internalURL.path,
                    destinationPath: destination.path,
                    sizeBytes: 0,
                    dryRun: dryRun,
                    messages: ["Internal cache was not present; external directory is ready"]
                )
            }
            migrations.append(migration)
        }

        let shellConfigurationURL = home.appendingPathComponent(".zshrc")
        if !dryRun {
            try updateShellConfiguration(
                at: shellConfigurationURL,
                targets: targets,
                externalRoot: externalRoot
            )
        }

        return CacheReport(
            enabled: true,
            reset: false,
            targets: migrations,
            shellConfigurationPath: shellConfigurationURL.path,
            dryRun: dryRun
        )
    }

    public func reset(dryRun: Bool) throws -> CacheReport {
        let shellConfigurationURL = homeDirectory.appendingPathComponent(".zshrc")
        if !dryRun, fileManager.fileExists(atPath: shellConfigurationURL.path) {
            let contents = try String(contentsOf: shellConfigurationURL, encoding: .utf8)
            let updated = Self.removingManagedBlock(from: contents)
            guard let data = updated.data(using: .utf8) else {
                throw MacBayError.unsupportedOperation("Unable to encode \(shellConfigurationURL.path)")
            }
            try data.write(to: shellConfigurationURL, options: .atomic)
        }
        return CacheReport(
            enabled: false,
            reset: true,
            targets: [],
            shellConfigurationPath: shellConfigurationURL.path,
            dryRun: dryRun
        )
    }

    private static func targets(homeDirectory: URL) -> [Target] {
        [
            Target(
                name: "npm",
                internalURL: homeDirectory.appendingPathComponent(".npm"),
                externalDirectoryName: "npm",
                environmentVariable: "npm_config_cache"
            ),
            Target(
                name: "uv",
                internalURL: homeDirectory.appendingPathComponent(".cache/uv"),
                externalDirectoryName: "uv",
                environmentVariable: "UV_CACHE_DIR"
            ),
            Target(
                name: "Gradle",
                internalURL: homeDirectory.appendingPathComponent(".gradle"),
                externalDirectoryName: "gradle",
                environmentVariable: "GRADLE_USER_HOME"
            ),
            Target(
                name: "Hugging Face",
                internalURL: homeDirectory.appendingPathComponent(".cache/huggingface"),
                externalDirectoryName: "huggingface",
                environmentVariable: "HF_HOME"
            )
        ]
    }

    private func updateShellConfiguration(
        at url: URL,
        targets: [Target],
        externalRoot: URL
    ) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = Self.managedBlock(targets: targets, externalRoot: externalRoot)
        let withoutBlock = Self.removingManagedBlock(from: existing)
        let separator = withoutBlock.isEmpty || withoutBlock.hasSuffix("\n") ? "" : "\n"
        let updated = withoutBlock + separator + block + "\n"
        guard let data = updated.data(using: .utf8) else {
            throw MacBayError.unsupportedOperation("Unable to encode \(url.path)")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func managedBlock(
        targets: [Target],
        externalRoot: URL
    ) -> String {
        var lines = [beginMarker]
        for target in targets {
            let path = externalRoot.appendingPathComponent(target.externalDirectoryName).path
            lines.append("export \(target.environmentVariable)=\"\(path)\"")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func removingManagedBlock(from contents: String) -> String {
        guard let start = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: start.upperBound..<contents.endIndex) else {
            return contents
        }
        var updated = contents
        updated.removeSubrange(start.lowerBound..<end.upperBound)
        while updated.hasSuffix("\n\n") {
            updated.removeLast()
        }
        return updated
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
