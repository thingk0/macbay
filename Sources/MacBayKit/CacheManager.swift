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
            failures: failures,
            dryRun: dryRun
        )
    }

    public func reset(dryRun: Bool) throws -> CacheReport {
        let shellConfigurationURL = homeDirectory.appendingPathComponent(".zshrc")
        let resolvedURL = shellConfigurationURL.resolvingSymlinksInPath()
        if !dryRun, fileManager.fileExists(atPath: resolvedURL.path) {
            let contents = try String(contentsOf: resolvedURL, encoding: .utf8)
            let updated = Self.removingManagedBlock(from: contents)
            guard let data = updated.data(using: .utf8) else {
                throw MacBayError.unsupportedOperation("Unable to encode \(resolvedURL.path)")
            }
            try data.write(to: resolvedURL, options: .atomic)
        }
        return CacheReport(
            enabled: false,
            reset: true,
            targets: [],
            shellConfigurationPath: shellConfigurationURL.path,
            dryRun: dryRun
        )
    }

    /// `~/.zshrc`에 관리 블록이 있는지만 확인한다. 파일이 없거나 읽을 수 없으면 false.
    public func isManagedBlockPresent() -> Bool {
        let resolvedURL = homeDirectory.appendingPathComponent(".zshrc").resolvingSymlinksInPath()
        guard let contents = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            return false
        }
        return contents.contains(Self.beginMarker)
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

    private func updateShellConfiguration(
        at url: URL,
        targets: [CacheTarget],
        externalRoot: URL
    ) throws {
        // ~/.zshrc가 dotfiles 저장소 등으로 향하는 심볼릭 링크인 경우, 원자적 쓰기는 링크 자체를
        // 일반 파일로 교체해 버린다. 실제 파일을 따라가서 그 파일을 수정한다.
        let url = url.resolvingSymlinksInPath()
        // 파일이 없을 때만 빈 내용으로 시작한다. 읽기·인코딩 실패를 빈 문자열로 취급하면
        // 사용자의 기존 설정을 통째로 덮어쓸 수 있으므로 반드시 중단한다.
        let existing: String
        if fileManager.fileExists(atPath: url.path) {
            do {
                existing = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MacBayError.unsupportedOperation(
                    "Unable to read \(url.path) as UTF-8; refusing to overwrite it (\(error.localizedDescription))"
                )
            }
        } else {
            existing = ""
        }
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
        targets: [CacheTarget],
        externalRoot: URL
    ) -> String {
        var lines = [beginMarker]
        for target in targets {
            let path = externalRoot.appendingPathComponent(target.externalDirectoryName).path
            lines.append("export \(target.environmentVariable)=\(shellQuoted(path))")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// 경로를 작은따옴표로 감싸 셸이 `$()`, 백틱, `$VAR` 등을 해석하지 않도록 한다.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
