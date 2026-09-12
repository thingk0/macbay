import Foundation

public struct CacheManager {
    private struct Target {
        let name: String
        let internalURL: URL
        let externalDirectoryName: String
        let environmentVariable: String
    }

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
        let writer = ShellEnvironmentWriter(fileManager: fileManager, homeDirectory: home)
        let variables = targets.map { target in
            ShellEnvironmentWriter.Variable(
                name: target.environmentVariable,
                value: externalRoot.appendingPathComponent(target.externalDirectoryName).path
            )
        }

        if !dryRun {
            let writeResult = try writer.write(variables: variables, guardPath: externalRoot)
            return CacheReport(
                enabled: true,
                reset: false,
                targets: migrations,
                shellConfigurationPath: shellConfigurationURL.path,
                shellConfigurationPaths: writeResult.updatedShellConfigurationPaths,
                environmentFilePath: writeResult.environmentFilePath,
                guardPath: writeResult.guardPath,
                dryRun: dryRun
            )
        } else {
            let envURL = home.appendingPathComponent(".config/macbay/cache-env.sh")
            let previewPaths = ShellEnvironmentWriter.plannedTargets(homeDirectory: home, fileManager: fileManager)

            return CacheReport(
                enabled: true,
                reset: false,
                targets: migrations,
                shellConfigurationPath: shellConfigurationURL.path,
                shellConfigurationPaths: previewPaths,
                environmentFilePath: envURL.path,
                guardPath: externalRoot.path,
                dryRun: dryRun
            )
        }
    }

    public func reset(dryRun: Bool) throws -> CacheReport {
        let home = homeDirectory
        let shellConfigurationURL = home.appendingPathComponent(".zshrc")
        let writer = ShellEnvironmentWriter(fileManager: fileManager, homeDirectory: home)
        var cleanedPaths: [String] = []
        if !dryRun {
            cleanedPaths = try writer.remove()
        }
        return CacheReport(
            enabled: false,
            reset: true,
            targets: [],
            shellConfigurationPath: shellConfigurationURL.path,
            shellConfigurationPaths: cleanedPaths.isEmpty ? [shellConfigurationURL.path] : cleanedPaths,
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

    /// 경로를 작은따옴표로 감싸 셸이 `$()`, 백틱, `$VAR` 등을 해석하지 않도록 한다.
    static func shellQuoted(_ value: String) -> String {
        ShellEnvironmentWriter.shellQuoted(value)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
