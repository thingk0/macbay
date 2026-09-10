import Foundation

public struct DeveloperCacheTarget: Equatable, Sendable {
    public let name: String
    public let path: URL

    public init(name: String, path: URL) {
        self.name = name
        self.path = path
    }
}

public struct AppScanner {
    public static let defaultMinimumApplicationSizeBytes: UInt64 = 200 * 1024 * 1024

    private let fileManager: FileManager
    private let sizeCalculator: FileSizeCalculator
    private let appInspector: AppInspector

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner(),
        appInspector: AppInspector? = nil
    ) {
        self.fileManager = fileManager
        self.sizeCalculator = FileSizeCalculator(fileManager: fileManager)
        self.appInspector = appInspector ?? AppInspector(fileManager: fileManager, commandRunner: commandRunner)
    }

    public func scan(
        minimumApplicationSizeBytes: UInt64 = AppScanner.defaultMinimumApplicationSizeBytes,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications")],
        developerCacheTargets: [DeveloperCacheTarget] = AppScanner.defaultDeveloperCacheTargets()
    ) -> ScanReport {
        var candidates: [AppCandidate] = []
        var warnings: [String] = []

        for directory in applicationDirectories {
            guard fileManager.fileExists(atPath: directory.path) else {
                warnings.append("Application directory is unavailable: \(directory.path)")
                continue
            }
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                warnings.append("Unable to read \(directory.path): \(error.localizedDescription)")
                continue
            }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                do {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    let sizeBytes = try sizeCalculator.size(of: entry)
                    if sizeBytes >= minimumApplicationSizeBytes {
                        let compatibility = appInspector.assess(bundleURL: entry)
                        candidates.append(AppCandidate(
                            name: entry.lastPathComponent,
                            path: entry.path,
                            sizeBytes: sizeBytes,
                            kind: .application,
                            compatibility: compatibility
                        ))
                    }
                } catch {
                    warnings.append("Unable to size \(entry.path): \(error.localizedDescription)")
                }
            }
        }

        for target in developerCacheTargets {
            guard fileManager.fileExists(atPath: target.path.path) else { continue }
            do {
                let sizeBytes = try sizeCalculator.size(of: target.path)
                if sizeBytes > 0 {
                    candidates.append(AppCandidate(
                        name: target.name,
                        path: target.path.path,
                        sizeBytes: sizeBytes,
                        kind: .developerCache
                    ))
                }
            } catch {
                warnings.append("Unable to size \(target.path.path): \(error.localizedDescription)")
            }
        }

        candidates.sort {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        return ScanReport(
            generatedAt: macBayTimestamp(),
            minimumApplicationSizeBytes: minimumApplicationSizeBytes,
            candidates: candidates,
            warnings: warnings
        )
    }

    public static func defaultDeveloperCacheTargets(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DeveloperCacheTarget] {
        [
            DeveloperCacheTarget(
                name: "Xcode iOS DeviceSupport",
                path: homeDirectory.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
            ),
            DeveloperCacheTarget(
                name: "CoreSimulator",
                path: homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator")
            ),
            DeveloperCacheTarget(name: "npm cache", path: homeDirectory.appendingPathComponent(".npm")),
            DeveloperCacheTarget(name: "uv cache", path: homeDirectory.appendingPathComponent(".cache/uv")),
            DeveloperCacheTarget(name: "Gradle", path: homeDirectory.appendingPathComponent(".gradle")),
            DeveloperCacheTarget(
                name: "Hugging Face cache",
                path: homeDirectory.appendingPathComponent(".cache/huggingface")
            )
        ]
    }
}
