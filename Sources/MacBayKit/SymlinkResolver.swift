import Foundation

public enum SymlinkResolution: Equatable, Sendable {
    case resolved(target: URL, hops: Int, usesRelativeDestination: Bool)
    case broken(targetPath: String, hops: Int)
    case circular(targetPath: String, hops: Int)
}

public struct SymlinkResolver: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(at url: URL, maxHops: Int = 32) -> SymlinkResolution {
        var currentURL = url
        var visitedPaths: Set<String> = [url.standardizedFileURL.path]
        var hops = 0
        var usesRelativeDestination = false

        while hops < maxHops {
            let destination: String
            do {
                destination = try fileManager.destinationOfSymbolicLink(atPath: currentURL.path)
            } catch {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) {
                    return .resolved(
                        target: currentURL.standardizedFileURL,
                        hops: hops,
                        usesRelativeDestination: usesRelativeDestination
                    )
                } else {
                    return .broken(targetPath: currentURL.standardizedFileURL.path, hops: hops)
                }
            }

            hops += 1
            let nextURL: URL
            if destination.hasPrefix("/") {
                nextURL = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                usesRelativeDestination = true
                nextURL = URL(fileURLWithPath: destination, relativeTo: currentURL.deletingLastPathComponent()).standardizedFileURL
            }

            if visitedPaths.contains(nextURL.path) {
                return .circular(targetPath: nextURL.path, hops: hops)
            }
            visitedPaths.insert(nextURL.path)
            currentURL = nextURL
        }

        return .circular(targetPath: currentURL.standardizedFileURL.path, hops: hops)
    }
}
