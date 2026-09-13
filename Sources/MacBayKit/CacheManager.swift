import Foundation

/// `mb cache`가 라우팅하는 개발자 캐시 한 대상. AppScanner도 이 목록을 재사용해
/// scan/doctor의 개발자 캐시 인식이 항상 동일하게 유지된다.
struct CacheTarget: Equatable, Sendable {
    let name: String
    let internalURL: URL
    let externalDirectoryName: String
    let environmentVariable: String
}

public struct CacheManager {

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

        var failures: [OperationFailure] = []
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
                do {
                    migration = try directoryMigrator.migrate(
                        source: target.internalURL,
                        destination: destination,
                        operation: "externalize cache",
                        dryRun: dryRun
                    )
                } catch {
                    // 한 대상의 실패로 나머지 캐시 라우팅과 셸 설정까지 멈추지 않는다.
                    let reason = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                    failures.append(OperationFailure(path: target.internalURL.path, reason: reason))
                    migration = MigrationResult(
                        operation: "externalize cache",
                        name: target.name,
                        sourcePath: target.internalURL.path,
                        destinationPath: destination.path,
                        sizeBytes: 0,
                        dryRun: dryRun,
                        messages: ["Failed: \(reason)"]
                    )
                }
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
                failures: failures,
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
                failures: failures,
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

    /// 관리되는 셸 설정 블록이나 cache-env 파일이 남아 있는지 확인한다.
    /// .zshrc 외에 .bashrc/.bash_profile/config.fish, ~/.config/macbay/cache-env.sh 도 확인한다.
    public func isManagedBlockPresent() -> Bool {
        let candidates = [
            homeDirectory.appendingPathComponent(".zshrc"),
            homeDirectory.appendingPathComponent(".bashrc"),
            homeDirectory.appendingPathComponent(".bash_profile"),
            homeDirectory.appendingPathComponent(".config/fish/config.fish")
        ]
        for url in candidates {
            let resolved = url.resolvingSymlinksInPath()
            if let contents = try? String(contentsOf: resolved, encoding: .utf8),
               contents.contains(ShellEnvironmentWriter.beginMarker) {
                return true
            }
        }
        let envFile = homeDirectory.appendingPathComponent(".config/macbay/cache-env.sh")
        return fileManager.fileExists(atPath: envFile.path)
    }

    static func targets(homeDirectory: URL) -> [CacheTarget] {
        [
            CacheTarget(
                name: "npm",
                internalURL: homeDirectory.appendingPathComponent(".npm"),
                externalDirectoryName: "npm",
                environmentVariable: "npm_config_cache"
            ),
            CacheTarget(
                // PNPM_HOME도 ~/Library/pnpm 아래에 있으므로 store 하위만 이동한다.
                name: "pnpm store",
                internalURL: homeDirectory.appendingPathComponent("Library/pnpm/store"),
                externalDirectoryName: "pnpm-store",
                environmentVariable: "npm_config_store_dir"
            ),
            CacheTarget(
                // Yarn v1과 Berry가 모두 YARN_CACHE_FOLDER를 존중하므로 하나의 변수로 라우팅한다.
                name: "Yarn cache",
                internalURL: homeDirectory.appendingPathComponent(".yarn/berry/cache"),
                externalDirectoryName: "yarn",
                environmentVariable: "YARN_CACHE_FOLDER"
            ),
            CacheTarget(
                name: "bun cache",
                internalURL: homeDirectory.appendingPathComponent(".bun/install/cache"),
                externalDirectoryName: "bun",
                environmentVariable: "BUN_INSTALL_CACHE_DIR"
            ),
            CacheTarget(
                name: "uv",
                internalURL: homeDirectory.appendingPathComponent(".cache/uv"),
                externalDirectoryName: "uv",
                environmentVariable: "UV_CACHE_DIR"
            ),
            CacheTarget(
                name: "pip",
                internalURL: homeDirectory.appendingPathComponent("Library/Caches/pip"),
                externalDirectoryName: "pip",
                environmentVariable: "PIP_CACHE_DIR"
            ),
            CacheTarget(
                name: "Gradle",
                internalURL: homeDirectory.appendingPathComponent(".gradle"),
                externalDirectoryName: "gradle",
                environmentVariable: "GRADLE_USER_HOME"
            ),
            CacheTarget(
                name: "CocoaPods",
                internalURL: homeDirectory.appendingPathComponent(".cocoapods"),
                externalDirectoryName: "cocoapods",
                environmentVariable: "CP_HOME_DIR"
            ),
            CacheTarget(
                name: "Go modules",
                internalURL: homeDirectory.appendingPathComponent("go/pkg/mod"),
                externalDirectoryName: "go-mod",
                environmentVariable: "GOMODCACHE"
            ),
            CacheTarget(
                name: "Android user data",
                internalURL: homeDirectory.appendingPathComponent(".android"),
                externalDirectoryName: "android",
                environmentVariable: "ANDROID_USER_HOME"
            ),
            CacheTarget(
                name: "Homebrew downloads",
                internalURL: homeDirectory.appendingPathComponent("Library/Caches/Homebrew"),
                externalDirectoryName: "homebrew",
                environmentVariable: "HOMEBREW_CACHE"
            ),
            CacheTarget(
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
