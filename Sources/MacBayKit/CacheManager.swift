import Foundation

/// `mb cache`가 라우팅하는 개발자 캐시 한 대상. AppScanner와 DirectoryMoveManager도 이 목록을
/// 재사용해 scan·doctor·teardown·move가 항상 같은 대상 집합을 보도록 한다.
struct CacheTarget: Equatable, Sendable {
    let name: String
    let internalURL: URL
    let externalDirectoryName: String
    /// nil이면 환경 변수를 내보내지 않고 내부 경로의 심볼릭 링크로만 라우팅한다.
    let environmentVariable: String?
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
        var variables: [ShellEnvironmentWriter.Variable] = []

        for target in targets {
            let destination = externalRoot.appendingPathComponent(target.externalDirectoryName, isDirectory: true)
            do {
                migrations.append(try route(target, to: destination, dryRun: dryRun))
                if let name = target.environmentVariable {
                    variables.append(ShellEnvironmentWriter.Variable(
                        name: name,
                        value: externalRoot.appendingPathComponent(target.externalDirectoryName).path
                    ))
                }
            } catch {
                // 한 대상의 실패로 나머지 캐시 라우팅과 셸 설정까지 멈추지 않는다. 실패한 대상의 캐시는
                // 내장에 그대로 남아 있으므로 그 환경 변수는 내보내지 않는다.
                let reason = (error as? MacBayError)?.errorDescription ?? error.localizedDescription
                failures.append(OperationFailure(path: target.internalURL.path, reason: reason))
                migrations.append(MigrationResult(
                    operation: "externalize cache",
                    name: target.name,
                    sourcePath: target.internalURL.path,
                    destinationPath: destination.path,
                    sizeBytes: 0,
                    dryRun: dryRun,
                    messages: ["Failed: \(reason)", "Environment export skipped"]
                ))
            }
        }

        let shellConfigurationURL = home.appendingPathComponent(".zshrc")
        let writer = ShellEnvironmentWriter(fileManager: fileManager, homeDirectory: home)

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

    /// 셸 설정(zsh·bash·fish) 중 하나에 관리 블록이 있거나 cache-env 파일이 남아 있으면 true.
    public func isManagedBlockPresent() -> Bool {
        ShellEnvironmentWriter(fileManager: fileManager, homeDirectory: homeDirectory).hasManagedConfiguration()
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
                // Berry는 enableGlobalCache(기본값 true)일 때 YARN_CACHE_FOLDER를 무시하고, 이 변수는 프로젝트
                // .yarnrc.yml의 cacheFolder까지 덮어써 zero-install 저장소를 깨뜨릴 수 있으므로 링크로만 라우팅한다.
                name: "Yarn Berry cache",
                internalURL: homeDirectory.appendingPathComponent(".yarn/berry/cache"),
                externalDirectoryName: "yarn-berry",
                environmentVariable: nil
            ),
            CacheTarget(
                // v1은 YARN_CACHE_FOLDER를 따르지만 같은 변수가 Berry 프로젝트 설정을 덮어쓰므로 역시 링크로만 라우팅한다.
                name: "Yarn v1 cache",
                internalURL: homeDirectory.appendingPathComponent("Library/Caches/Yarn"),
                externalDirectoryName: "yarn-v1",
                environmentVariable: nil
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

    private func route(_ target: CacheTarget, to destination: URL, dryRun: Bool) throws -> MigrationResult {
        if isSymbolicLink(target.internalURL) {
            return configured(target, destination: destination, dryRun: dryRun, message: "Internal cache is already a symbolic link")
        }
        if fileManager.fileExists(atPath: target.internalURL.path) {
            return try directoryMigrator.migrate(
                source: target.internalURL,
                destination: destination,
                operation: "externalize cache",
                dryRun: dryRun
            )
        }
        if !dryRun {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        guard target.environmentVariable == nil else {
            return configured(target, destination: destination, dryRun: dryRun, message: "Internal cache was not present; external directory is ready")
        }
        // 환경 변수로 라우팅하지 않는 대상은 링크가 유일한 경로이므로, 캐시가 아직 없어도 링크를 만들어 둔다.
        if !dryRun {
            try fileManager.createDirectory(
                at: target.internalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(atPath: target.internalURL.path, withDestinationPath: destination.path)
        }
        return configured(target, destination: destination, dryRun: dryRun, message: "Internal cache was not present; linked to the external directory")
    }

    private func configured(_ target: CacheTarget, destination: URL, dryRun: Bool, message: String) -> MigrationResult {
        MigrationResult(
            operation: "configure cache",
            name: target.name,
            sourcePath: target.internalURL.path,
            destinationPath: destination.path,
            sizeBytes: 0,
            dryRun: dryRun,
            messages: [message]
        )
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
