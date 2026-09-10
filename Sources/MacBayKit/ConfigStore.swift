import Foundation

public struct ConfigStore {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public var configURL: URL {
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"],
           xdgConfigHome.hasPrefix("/") {
            return URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
                .appendingPathComponent("macbay/config.json")
        }
        return homeDirectory.appendingPathComponent(".config/macbay/config.json")
    }

    public func load() throws -> MacBayConfig {
        let url = configURL
        guard fileManager.fileExists(atPath: url.path) else {
            return MacBayConfig()
        }

        let config: MacBayConfig
        do {
            config = try decoder.decode(MacBayConfig.self, from: try Data(contentsOf: url))
        } catch {
            throw MacBayError.configFailed(path: url.path, details: error.localizedDescription)
        }

        guard config.version == MacBayConfig.currentVersion else {
            throw MacBayError.configFailed(
                path: url.path,
                details: "Unsupported configuration version \(config.version) (expected \(MacBayConfig.currentVersion))"
            )
        }
        return config
    }

    public func save(_ config: MacBayConfig) throws {
        let url = configURL
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            throw MacBayError.configFailed(path: url.path, details: error.localizedDescription)
        }
    }

    public func reset() throws -> DefaultVolume? {
        let url = configURL
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let removed = (try? load())?.defaultVolume
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw MacBayError.configFailed(path: url.path, details: error.localizedDescription)
        }
        return removed
    }
}
