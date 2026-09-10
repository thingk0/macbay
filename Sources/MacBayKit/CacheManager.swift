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
        targets: [Target],
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
