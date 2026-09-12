import Foundation

struct ExternalReferenceValidator {
    private let fileManager: FileManager
    private let symlinkResolver: SymlinkResolver

    init(
        fileManager: FileManager = .default,
        symlinkResolver: SymlinkResolver? = nil
    ) {
        self.fileManager = fileManager
        self.symlinkResolver = symlinkResolver ?? SymlinkResolver(fileManager: fileManager)
    }

    func scanApplicationDirectories(_ directories: [URL]) -> ExternalApplicationScan {
        var candidatesByName: [String: [ReplacementApp]] = [:]
        var unreadableDirectories: [String] = []

        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                unreadableDirectories.append(directory.path)
                continue
            }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                let listingPath = entry.standardizedFileURL.path
                let identity = resolvedIdentity(of: listingPath)
                candidatesByName[entry.lastPathComponent.lowercased(), default: []].append(
                    ReplacementApp(listingPath: listingPath, identity: identity)
                )
            }
        }

        var unique: [String: [ReplacementApp]] = [:]
        for (name, listings) in candidatesByName {
            unique[name] = deduplicated(listings)
        }

        return ExternalApplicationScan(
            candidatesByName: unique,
            unreadableDirectories: unreadableDirectories.sorted()
        )
    }

    func existence(of path: String) -> ExternalPathExistence {
        if ConfigFileIO.isSymbolicLink(at: path, fileManager: fileManager) {
            switch symlinkResolver.resolve(at: URL(fileURLWithPath: path)) {
            case .broken:
                return .missing
            case let .circular(targetPath, _):
                return .indeterminate("the path is a circular link (\(targetPath))")
            case .resolved:
                return .exists
            }
        }

        if fileManager.fileExists(atPath: path) {
            return .exists
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var deepestExisting = "/"
        for component in components {
            let candidate = deepestExisting == "/" ? "/" + component : deepestExisting + "/" + component
            guard fileManager.fileExists(atPath: candidate) else { break }
            deepestExisting = candidate
        }

        if deepestExisting != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: deepestExisting, isDirectory: &isDirectory), isDirectory.boolValue {
                if !fileManager.isReadableFile(atPath: deepestExisting) || !fileManager.isExecutableFile(atPath: deepestExisting) {
                    return .indeterminate("permission was denied while checking \(deepestExisting)")
                }
            }
        }

        return .missing
    }

    func classify(reference: AppPathReference, scan: ExternalApplicationScan) -> ExternalReferenceOutcome {
        if !scan.unreadableDirectories.isEmpty {
            let joined = scan.unreadableDirectories.joined(separator: ", ")
            let noun = scan.unreadableDirectories.count == 1 ? "directory" : "directories"
            return .unverified(reason: "application \(noun) \(joined) could not be read, so a unique local match could not be confirmed")
        }

        let matches = scan.candidatesByName[reference.appFileName.lowercased()] ?? []
        if matches.isEmpty {
            return .missing(reason: "no application named '\(reference.appFileName)' was found in the checked application directories")
        }

        let resolved = matches.filter { $0.identity != nil }
        let identities = Set(resolved.compactMap(\.identity))
        if identities.count > 1 {
            let listed = matches.map(\.listingPath).sorted().joined(separator: ", ")
            return .unverified(reason: "multiple applications named '\(reference.appFileName)' were found: \(listed)")
        }

        guard let app = preferred(matches) else {
            if let broken = matches.first {
                return classifyUnresolvedApp(at: broken.listingPath)
            }
            return .missing(reason: "no application named '\(reference.appFileName)' was found in the checked application directories")
        }

        if ConfigFileIO.isSymbolicLink(at: app.listingPath, fileManager: fileManager) {
            if case let .unverified(reason) = classifyUnresolvedApp(at: app.listingPath) {
                return .unverified(reason: reason)
            }
        }

        if !fileManager.isReadableFile(atPath: app.listingPath) || !fileManager.isExecutableFile(atPath: app.listingPath) {
            return .unverified(reason: "permission was denied while checking \(app.listingPath)")
        }

        guard !reference.internalPath.isEmpty else {
            return .candidate(path: app.listingPath, appPath: app.listingPath)
        }

        let candidatePath = app.listingPath + "/" + reference.internalPath
        switch existence(of: candidatePath) {
        case .exists:
            return .candidate(path: candidatePath, appPath: app.listingPath)
        case .missing:
            return .missing(reason: "the same relative path '\(reference.internalPath)' was not found under \(app.listingPath)")
        case .indeterminate(let reason):
            return .unverified(reason: reason)
        }
    }

    private func classifyUnresolvedApp(at path: String) -> ExternalReferenceOutcome {
        switch symlinkResolver.resolve(at: URL(fileURLWithPath: path)) {
        case let .broken(targetPath, _):
            return .unverified(reason: "the matching application link at \(path) is broken (target: \(targetPath))")
        case let .circular(targetPath, _):
            return .unverified(reason: "the matching application link at \(path) is circular (\(targetPath))")
        case .resolved:
            return .unverified(reason: "the matching application at \(path) could not be verified")
        }
    }

    private func resolvedIdentity(of path: String) -> FileIdentity? {
        if ConfigFileIO.isSymbolicLink(at: path, fileManager: fileManager) {
            switch symlinkResolver.resolve(at: URL(fileURLWithPath: path)) {
            case let .resolved(target, _, _):
                return ConfigFileIO.identity(at: target.path, follow: true)
            case .broken, .circular:
                return nil
            }
        }
        return ConfigFileIO.identity(at: path, follow: true)
    }

    private func deduplicated(_ listings: [ReplacementApp]) -> [ReplacementApp] {
        var byIdentity: [FileIdentity: [ReplacementApp]] = [:]
        var unresolved: [ReplacementApp] = []
        for listing in listings {
            if let identity = listing.identity {
                byIdentity[identity, default: []].append(listing)
            } else {
                unresolved.append(listing)
            }
        }

        var result: [ReplacementApp] = []
        for group in byIdentity.values {
            if let preferred = preferred(group) {
                result.append(preferred)
            }
        }
        result.append(contentsOf: unresolved)
        return result
    }

    private func preferred(_ listings: [ReplacementApp]) -> ReplacementApp? {
        let resolved = listings.filter { $0.identity != nil }
        let pool = resolved.isEmpty ? listings : resolved
        return pool.min { lhs, rhs in
            let left = preference(lhs.listingPath)
            let right = preference(rhs.listingPath)
            if left != right { return left < right }
            return lhs.listingPath.localizedCaseInsensitiveCompare(rhs.listingPath) == .orderedAscending
        }
    }

    private func preference(_ path: String) -> Int {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        if parent.caseInsensitiveCompare("/Applications") == .orderedSame { return 0 }
        if URL(fileURLWithPath: parent).lastPathComponent.caseInsensitiveCompare("Applications") == .orderedSame {
            return 1
        }
        return 2
    }
}
