import Foundation

struct ConfigDiscovery {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL
    private let currentDirectory: URL
    private let limits: ConfigScanLimits

    init(
        fileManager: FileManager,
        environment: [String: String],
        homeDirectory: URL,
        currentDirectory: URL,
        limits: ConfigScanLimits
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.currentDirectory = currentDirectory.standardizedFileURL
        self.limits = limits
    }

    func discover(paths: [String]) -> ConfigDiscoveryResult {
        var state = ScanState()

        for raw in paths {
            let url = ExternalConfigPaths.resolveUserPath(
                raw,
                homeDirectory: homeDirectory,
                currentDirectory: currentDirectory
            )
            let pathKey = url.standardizedFileURL.path
            if !state.seenPaths.insert(pathKey).inserted { continue }

            let standardized = url.standardizedFileURL
            if ConfigFileIO.isSymbolicLink(at: standardized.path, fileManager: fileManager) {
                guard let target = resolvedRegularFile(standardized) else {
                    state.issues.append(ConfigDiscoveryIssue(
                        url: url,
                        reason: "the path could not be read",
                        kind: .inaccessible
                    ))
                    continue
                }
                considerFile(target, displayURL: url, state: &state)
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            if !exists {
                state.issues.append(ConfigDiscoveryIssue(
                    url: url,
                    reason: "the path does not exist",
                    kind: .missingAdditional
                ))
                continue
            }
            if isDirectory.boolValue {
                state.issues.append(ConfigDiscoveryIssue(
                    url: url,
                    reason: "the path is a directory; pass individual files with --path",
                    kind: .missingAdditional
                ))
                continue
            }
            considerFile(standardized, displayURL: url, state: &state)
        }

        if state.files.count > limits.maxConfigFiles {
            let overflow = Array(state.files[limits.maxConfigFiles...]).map(\.url.path)
            state.files = Array(state.files.prefix(limits.maxConfigFiles))
            recordLimit(&state, url: nil, reason: "the configuration file limit of \(limits.maxConfigFiles) was reached (\(overflow.joined(separator: ", ")))")
        }

        state.files.sort { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        state.issues.sort { lhs, rhs in
            (lhs.url?.path ?? "").localizedCaseInsensitiveCompare(rhs.url?.path ?? "") == .orderedAscending
        }
        return ConfigDiscoveryResult(files: state.files, issues: state.issues)
    }

    private struct ScanState {
        var files: [DiscoveredConfigFile] = []
        var issues: [ConfigDiscoveryIssue] = []
        var seenIdentities: Set<FileIdentity> = []
        var seenPaths: Set<String> = []
    }

    private func considerFile(
        _ url: URL,
        displayURL: URL,
        state: inout ScanState
    ) {
        let name = url.lastPathComponent
        if Self.isBackupName(name) || name == ".DS_Store" {
            state.issues.append(ConfigDiscoveryIssue(
                url: displayURL,
                reason: "the file is a backup or system file and was skipped",
                kind: .inaccessible
            ))
            return
        }

        guard let format = Self.format(for: url) else {
            state.issues.append(ConfigDiscoveryIssue(
                url: displayURL,
                reason: "the file type is not supported",
                kind: .inaccessible
            ))
            return
        }

        let target = resolvedRegularFile(url) ?? url
        if let identity = ConfigFileIO.identity(at: target.path, follow: true) {
            if !state.seenIdentities.insert(identity).inserted { return }
        }

        state.files.append(DiscoveredConfigFile(url: target, format: format))
    }

    private func resolvedRegularFile(_ url: URL) -> URL? {
        guard ConfigFileIO.isSymbolicLink(at: url.path, fileManager: fileManager) else {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
            return nil
        }

        var seen = Set<String>()
        var current = url
        for _ in 0..<32 {
            let path = current.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current.path) else {
                return nil
            }
            let resolved: URL
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination)
            } else {
                resolved = current.deletingLastPathComponent().appendingPathComponent(destination)
            }
            if ConfigFileIO.isSymbolicLink(at: resolved.path, fileManager: fileManager) {
                current = resolved
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            return resolved
        }
        return nil
    }

    private func recordLimit(_ state: inout ScanState, url: URL?, reason: String) {
        let issue = ConfigDiscoveryIssue(url: url, reason: reason, kind: .limitReached)
        if !state.issues.contains(where: { $0.kind == .limitReached && $0.reason == reason }) {
            state.issues.append(issue)
        }
    }

    private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    static func isBackupName(_ name: String) -> Bool {
        name.hasSuffix("~")
            || name.lowercased().hasSuffix(".bak")
            || name.lowercased().hasSuffix(".backup")
            || name.lowercased().hasSuffix(".orig")
    }

    static func format(for url: URL) -> ConfigFileFormat? {
        let name = url.lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") { return .text }

        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "plist": return .plist
        case "toml": return .toml
        case "yaml", "yml": return .yaml
        case "ini", "conf", "cfg", "properties", "env", "sh", "bash", "zsh":
            return .text
        default:
            return .text
        }
    }
}
