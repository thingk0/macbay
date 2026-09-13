import Foundation

public struct ShellEnvironmentWriter {
    public static let beginMarker = "# >>> macbay cache >>>"
    public static let endMarker = "# <<< macbay cache <<<"

    public struct Variable: Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct WriteResult: Sendable {
        public let environmentFilePath: String
        public let fishEnvironmentFilePath: String?
        public let updatedShellConfigurationPaths: [String]
        public let guardPath: String

        public init(
            environmentFilePath: String,
            fishEnvironmentFilePath: String?,
            updatedShellConfigurationPaths: [String],
            guardPath: String
        ) {
            self.environmentFilePath = environmentFilePath
            self.fishEnvironmentFilePath = fishEnvironmentFilePath
            self.updatedShellConfigurationPaths = updatedShellConfigurationPaths
            self.guardPath = guardPath
        }
    }

    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(fileManager: FileManager = .default, homeDirectory: URL) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    /// 경로를 작은따옴표로 감싸 셸이 `$()`, 백틱, `$VAR` 등을 해석하지 않도록 한다.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func removingManagedBlock(from contents: String) -> String {
        guard let start = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: start.upperBound..<contents.endIndex) else {
            return contents
        }
        var endPos = end.upperBound
        if endPos < contents.endIndex && contents[endPos] == "\n" {
            endPos = contents.index(after: endPos)
        }
        var updated = contents
        updated.removeSubrange(start.lowerBound..<endPos)
        while updated.hasSuffix("\n\n") {
            updated.removeLast()
        }
        return updated
    }

    public static func plannedTargets(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var targets = [homeDirectory.appendingPathComponent(".zshrc").path]
        let bashrc = homeDirectory.appendingPathComponent(".bashrc")
        if fileManager.fileExists(atPath: bashrc.path) {
            targets.append(bashrc.path)
        }
        let bashProfile = homeDirectory.appendingPathComponent(".bash_profile")
        if fileManager.fileExists(atPath: bashProfile.path) {
            targets.append(bashProfile.path)
        }
        let fishDir = homeDirectory.appendingPathComponent(".config/fish")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: fishDir.path, isDirectory: &isDir) && isDir.boolValue {
            targets.append(fishDir.appendingPathComponent("config.fish").path)
        }
        return targets
    }

    public func write(variables: [Variable], guardPath: URL) throws -> WriteResult {
        let configDir = homeDirectory.appendingPathComponent(".config/macbay", isDirectory: true)
        if !fileManager.fileExists(atPath: configDir.path) {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        let posixEnvURL = configDir.appendingPathComponent("cache-env.sh")
        let fishEnvURL = configDir.appendingPathComponent("cache-env.fish")

        var posixLines: [String] = []
        for variable in variables {
            posixLines.append("export \(variable.name)=\(Self.shellQuoted(variable.value))")
        }
        let posixContent = posixLines.isEmpty ? "" : posixLines.joined(separator: "\n") + "\n"
        guard let posixData = posixContent.data(using: .utf8) else {
            throw MacBayError.unsupportedOperation("Unable to encode \(posixEnvURL.path)")
        }
        try posixData.write(to: posixEnvURL, options: .atomic)

        let fishDir = homeDirectory.appendingPathComponent(".config/fish", isDirectory: true)
        var isDir: ObjCBool = false
        let fishConfigTargetExists = fileManager.fileExists(atPath: fishDir.path, isDirectory: &isDir) && isDir.boolValue

        var fishEnvPath: String? = nil
        if fishConfigTargetExists {
            var fishLines: [String] = []
            for variable in variables {
                fishLines.append("set -gx \(variable.name) \(Self.shellQuoted(variable.value))")
            }
            let fishContent = fishLines.isEmpty ? "" : fishLines.joined(separator: "\n") + "\n"
            guard let fishData = fishContent.data(using: .utf8) else {
                throw MacBayError.unsupportedOperation("Unable to encode \(fishEnvURL.path)")
            }
            try fishData.write(to: fishEnvURL, options: .atomic)
            fishEnvPath = fishEnvURL.path
        }

        let posixBlock = [
            Self.beginMarker,
            "if [ -d \(Self.shellQuoted(guardPath.path)) ]; then . \(Self.shellQuoted(posixEnvURL.path)); fi",
            Self.endMarker
        ].joined(separator: "\n")

        var updatedPaths: [String] = []

        // 1. ~/.zshrc (created if absent, required)
        let zshrcURL = homeDirectory.appendingPathComponent(".zshrc")
        if try updateTargetFile(at: zshrcURL, block: posixBlock, createIfMissing: true, required: true) {
            updatedPaths.append(zshrcURL.path)
        }

        // 2. ~/.bashrc (updated only if already exists, secondary)
        let bashrcURL = homeDirectory.appendingPathComponent(".bashrc")
        if try updateTargetFile(at: bashrcURL, block: posixBlock, createIfMissing: false, required: false) {
            updatedPaths.append(bashrcURL.path)
        }

        // 3. ~/.bash_profile (updated only if already exists, secondary)
        let bashProfileURL = homeDirectory.appendingPathComponent(".bash_profile")
        if try updateTargetFile(at: bashProfileURL, block: posixBlock, createIfMissing: false, required: false) {
            updatedPaths.append(bashProfileURL.path)
        }

        // 4. ~/.config/fish/config.fish (only if ~/.config/fish directory exists, secondary)
        if fishConfigTargetExists, let fishEnvPath = fishEnvPath {
            let fishConfigFileURL = fishDir.appendingPathComponent("config.fish")
            let fishBlock = [
                Self.beginMarker,
                "test -d \(Self.shellQuoted(guardPath.path)); and source \(Self.shellQuoted(fishEnvPath))",
                Self.endMarker
            ].joined(separator: "\n")
            if try updateTargetFile(at: fishConfigFileURL, block: fishBlock, createIfMissing: true, required: false) {
                updatedPaths.append(fishConfigFileURL.path)
            }
        }

        return WriteResult(
            environmentFilePath: posixEnvURL.path,
            fishEnvironmentFilePath: fishEnvPath,
            updatedShellConfigurationPaths: updatedPaths,
            guardPath: guardPath.path
        )
    }

    public func remove() throws -> [String] {
        var cleanedPaths: [String] = []

        for url in Self.managedShellConfigurationURLs(homeDirectory: homeDirectory) {
            let resolved = url.resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: resolved.path) else { continue }

            let contents: String
            do {
                contents = try String(contentsOf: resolved, encoding: .utf8)
            } catch {
                continue
            }

            if contents.contains(Self.beginMarker) {
                let updated = Self.removingManagedBlock(from: contents)
                guard let data = updated.data(using: .utf8) else {
                    throw MacBayError.unsupportedOperation("Unable to encode \(resolved.path)")
                }
                try data.write(to: resolved, options: .atomic)
                cleanedPaths.append(url.path)
            }
        }

        let configDir = homeDirectory.appendingPathComponent(".config/macbay", isDirectory: true)
        let posixEnvURL = configDir.appendingPathComponent("cache-env.sh")
        let fishEnvURL = configDir.appendingPathComponent("cache-env.fish")

        if fileManager.fileExists(atPath: posixEnvURL.path) {
            try? fileManager.removeItem(at: posixEnvURL)
        }
        if fileManager.fileExists(atPath: fishEnvURL.path) {
            try? fileManager.removeItem(at: fishEnvURL)
        }

        return cleanedPaths
    }

    /// 관리 블록이 남아 있는 셸 설정이 있거나 cache-env 파일이 남아 있으면 true.
    public func hasManagedConfiguration() -> Bool {
        for url in Self.managedShellConfigurationURLs(homeDirectory: homeDirectory) {
            let resolved = url.resolvingSymlinksInPath()
            if let contents = try? String(contentsOf: resolved, encoding: .utf8),
               contents.contains(Self.beginMarker) {
                return true
            }
        }
        let configDir = homeDirectory.appendingPathComponent(".config/macbay", isDirectory: true)
        return ["cache-env.sh", "cache-env.fish"].contains { name in
            fileManager.fileExists(atPath: configDir.appendingPathComponent(name).path)
        }
    }

    private static func managedShellConfigurationURLs(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".zshrc"),
            homeDirectory.appendingPathComponent(".bashrc"),
            homeDirectory.appendingPathComponent(".bash_profile"),
            homeDirectory.appendingPathComponent(".config/fish/config.fish")
        ]
    }

    private func updateTargetFile(
        at url: URL,
        block: String,
        createIfMissing: Bool,
        required: Bool
    ) throws -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let exists = fileManager.fileExists(atPath: resolved.path)
        if !exists && !createIfMissing {
            return false
        }

        let existing: String
        if exists {
            do {
                existing = try String(contentsOf: resolved, encoding: .utf8)
            } catch {
                guard required else { return false }
                throw MacBayError.unsupportedOperation(
                    "Unable to read \(resolved.path) as UTF-8; refusing to overwrite it (\(error.localizedDescription))"
                )
            }
        } else {
            existing = ""
        }

        let withoutBlock = Self.removingManagedBlock(from: existing)
        let separator = withoutBlock.isEmpty || withoutBlock.hasSuffix("\n") ? "" : "\n"
        let updated = withoutBlock + separator + block + "\n"
        guard let data = updated.data(using: .utf8) else {
            throw MacBayError.unsupportedOperation("Unable to encode \(resolved.path)")
        }
        let parent = resolved.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: resolved, options: .atomic)
        return true
    }
}
