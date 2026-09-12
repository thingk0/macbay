import Foundation

public struct ExternalReferenceChecker {
    private struct ReferenceGroup {
        let reference: AppPathReference
        var locations: [String] = []
        var notes: [String] = []

        mutating func add(location: String, note: String?) {
            if !locations.contains(location) {
                locations.append(location)
            }
            if let note, !notes.contains(note) {
                notes.append(note)
            }
        }
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL
    private let currentDirectory: URL
    private let limits: ConfigScanLimits
    private let discovery: ConfigDiscovery
    private let reader = ConfigFileReader()
    private let validator: ExternalReferenceValidator

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        currentDirectory: URL? = nil,
        limits: ConfigScanLimits = .standard
    ) {
        self.fileManager = fileManager
        self.environment = environment
        let home = homeDirectory ?? ExternalConfigPaths.homeDirectory(environment: environment, fileManager: fileManager)
        self.homeDirectory = home
        self.currentDirectory = currentDirectory
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        self.limits = limits
        self.discovery = ConfigDiscovery(
            fileManager: fileManager,
            environment: environment,
            homeDirectory: home,
            currentDirectory: self.currentDirectory,
            limits: limits
        )
        self.validator = ExternalReferenceValidator(fileManager: fileManager)
    }

    public static func defaultApplicationDirectories(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public func check(
        paths: [String],
        applicationDirectories: [URL]? = nil
    ) -> ExternalReferenceCheckResult {
        let apps = applicationDirectories ?? Self.defaultApplicationDirectories(homeDirectory: homeDirectory)
        let discoveryResult = discovery.discover(paths: paths)
        let scan = validator.scanApplicationDirectories(apps)

        var findings: [DoctorFinding] = []
        var remainingReadBudget = limits.maxTotalReadBytes
        var inspected: [DiscoveredConfigFile] = []
        var truncatedFiles: [String] = []
        var usedHeuristic = false

        let accessIssues = discoveryResult.issues.filter { $0.kind == .inaccessible || $0.kind == .missingAdditional }
        let limitIssues = discoveryResult.issues.filter { $0.kind == .limitReached }

        if !accessIssues.isEmpty {
            let paths = accessIssues.compactMap { $0.url?.path }
            let reasons = accessIssues.map(\.reason).joined(separator: "; ")
            findings.append(Self.unreadableFinding(
                name: "configuration scan",
                paths: paths.isEmpty ? [] : paths,
                reason: reasons
            ))
        }

        for file in discoveryResult.files {
            switch ConfigFileIO.readLimited(at: file.url, fileManager: fileManager, maxBytes: min(limits.maxFileBytes, max(0, remainingReadBudget))) {
            case .failure(let reason):
                findings.append(Self.unreadableFinding(path: file.url.path, reason: reason))
            case let .success(data, truncated):
                remainingReadBudget -= data.count
                if truncated {
                    truncatedFiles.append(file.url.path)
                    if remainingReadBudget <= 0 { break }
                    continue
                }

                inspected.append(file)

                let extraction = reader.read(file: file, data: data)
                if extraction.references.contains(where: { $0.method == ExtractionMethod.text }) {
                    usedHeuristic = true
                }
                if let error = extraction.error {
                    findings.append(Self.unreadableFinding(path: file.url.path, reason: error))
                    continue
                }
                findings.append(contentsOf: issueFindings(extraction: extraction, file: file))
                findings.append(contentsOf: referenceFindings(extraction: extraction, file: file, scan: scan))
            }
            if remainingReadBudget <= 0 { break }
        }

        if remainingReadBudget <= 0, inspected.count < discoveryResult.files.count {
            truncatedFiles.append(contentsOf: discoveryResult.files.dropFirst(inspected.count).map(\.url.path))
        }

        var scanReasons: [String] = limitIssues.map(\.reason)
        if !truncatedFiles.isEmpty {
            scanReasons.append("a read limit of \(Self.byteLimitDescription(limits.maxFileBytes)) per file or \(Self.byteLimitDescription(limits.maxTotalReadBytes)) total was reached")
        }
        if remainingReadBudget <= 0, truncatedFiles.isEmpty, inspected.count < discoveryResult.files.count {
            scanReasons.append("the total read limit of \(Self.byteLimitDescription(limits.maxTotalReadBytes)) was reached")
        }
        if !scanReasons.isEmpty {
            let paths = (limitIssues.compactMap(\.url?.path) + truncatedFiles)
            findings.append(DoctorFinding(
                code: .externalReferenceScanIncomplete,
                status: .unableToVerify,
                category: .externalReference,
                name: "configuration scan",
                paths: Array(Set(paths)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                detail: "Inspection stopped after reaching a limit: \(scanReasons.joined(separator: "; ")). Some settings were not inspected.",
                recommendation: "Inspect the remaining files manually. Only the files passed with --path are checked; MacBay does not change configuration files."
            ))
        }

        findings.sort(by: Self.isOrderedBefore)
        let skipped = skippedFindings(in: findings)
        return ExternalReferenceCheckResult(
            findings: findings.filter { !skipped.contains($0.id) },
            notes: notes(
                files: inspected,
                usedHeuristic: usedHeuristic,
                skippedCount: skipped.count
            )
        )
    }

    private func skippedFindings(in findings: [DoctorFinding]) -> Set<String> {
        Set(findings.filter { Self.isSkippedNonConfigReference($0) }.map(\.id))
    }

    static func isSkippedNonConfigReference(_ finding: DoctorFinding) -> Bool {
        guard finding.category == .externalReference else { return false }
        guard finding.code == .externalReferenceMissing else { return false }
        guard finding.paths.count >= 2 else { return false }
        let configured = finding.paths[1]
        if configured.contains("*") || configured.contains("?") || configured.contains("[") { return true }
        if configured.contains("{") || configured.contains("}") { return true }
        if configured.contains("<") || configured.contains(">") { return true }
        let fileName = URL(fileURLWithPath: configured).lastPathComponent
        if fileName == "AppName.app" { return true }
        return false
    }

    private func issueFindings(extraction: ConfigReadResult, file: DiscoveredConfigFile) -> [DoctorFinding] {
        let relevant = extraction.issues.filter(\.confirmedOmission)
        guard !relevant.isEmpty else { return [] }

        let sorted = relevant.sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location.localizedCaseInsensitiveCompare(rhs.location) == .orderedAscending
            }
            return lhs.reason.localizedCaseInsensitiveCompare(rhs.reason) == .orderedAscending
        }
        let description = sorted.map { "\($0.location) (\($0.reason))" }.joined(separator: "; ")

        return [DoctorFinding(
            code: .externalConfigPartiallyChecked,
            status: .unableToVerify,
            category: .externalReference,
            name: file.url.lastPathComponent,
            paths: [file.url.path],
            detail: "Not fully inspected: \(description).",
            recommendation: "Confirm whether this setting is currently in use, then review the affected values manually; MacBay's limited reader skips unsupported constructs and does not change configuration files."
        )]
    }

    private func referenceFindings(
        extraction: ConfigReadResult,
        file: DiscoveredConfigFile,
        scan: ExternalApplicationScan
    ) -> [DoctorFinding] {
        var groups: [String: ReferenceGroup] = [:]
        for reference in extraction.references {
            guard let parsed = AppPathReference.parse(reference.path) else { continue }
            var group = groups[parsed.path] ?? ReferenceGroup(reference: parsed)
            group.add(location: reference.location, note: reference.note)
            groups[parsed.path] = group
        }

        return groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { key in
                guard let group = groups[key] else { return nil }
                switch validator.existence(of: group.reference.path) {
                case .exists:
                    return nil
                case .indeterminate(let reason):
                    return unverifiedFinding(file: file, group: group, reason: reason)
                case .missing:
                    switch validator.classify(reference: group.reference, scan: scan) {
                    case .current:
                        return nil
                    case let .candidate(candidatePath, appPath):
                        return candidateFinding(file: file, group: group, candidatePath: candidatePath, appPath: appPath)
                    case .missing(let reason):
                        return missingFinding(file: file, group: group, reason: reason)
                    case .unverified(let reason):
                        return unverifiedFinding(file: file, group: group, reason: reason)
                    }
                }
            }
    }

    private func candidateFinding(
        file: DiscoveredConfigFile,
        group: ReferenceGroup,
        candidatePath: String,
        appPath: String
    ) -> DoctorFinding {
        let missingDescription = group.reference.internalPath.isEmpty
            ? "a same-named application exists at \(appPath)"
            : "the same relative path exists under \(appPath)"

        return DoctorFinding(
            code: .externalReferenceStaleCandidate,
            status: .needsAttention,
            category: .externalReference,
            name: group.reference.appFileName,
            paths: [file.url.path, group.reference.path, candidatePath],
            detail: "\(referenceDescription(group)) The configured path is missing; \(missingDescription).\(volumeNote(for: group.reference)) MacBay does not confirm whether this setting is currently in use.",
            recommendation: "Confirm whether this setting is currently in use, then back it up and update the path if needed. MacBay does not change configuration files.",
            referenceLocations: sortedLocations(group.locations)
        )
    }

    private func missingFinding(
        file: DiscoveredConfigFile,
        group: ReferenceGroup,
        reason: String
    ) -> DoctorFinding {
        DoctorFinding(
            code: .externalReferenceMissing,
            status: .needsAttention,
            category: .externalReference,
            name: group.reference.appFileName,
            paths: [file.url.path, group.reference.path],
            detail: "\(referenceDescription(group)) The configured path is missing; \(reason).\(volumeNote(for: group.reference)) MacBay does not confirm whether this setting is currently in use.",
            recommendation: "Confirm whether this setting is currently in use, then back it up and update the path if needed. MacBay does not change configuration files.",
            referenceLocations: sortedLocations(group.locations)
        )
    }

    private func unverifiedFinding(
        file: DiscoveredConfigFile,
        group: ReferenceGroup,
        reason: String
    ) -> DoctorFinding {
        DoctorFinding(
            code: .externalReferenceUnverified,
            status: .unableToVerify,
            category: .externalReference,
            name: group.reference.appFileName,
            paths: [file.url.path, group.reference.path],
            detail: "\(referenceDescription(group)) Unable to verify the configured path: \(reason). MacBay does not confirm whether this setting is currently in use.",
            recommendation: "Confirm whether this setting is currently in use, then verify the configured path manually. MacBay does not change configuration files.",
            referenceLocations: sortedLocations(group.locations)
        )
    }

    private func referenceDescription(_ group: ReferenceGroup) -> String {
        let locations = sortedLocations(group.locations).joined(separator: ", ")
        var text = "Referenced at \(locations)."
        if !group.notes.isEmpty {
            let names = group.notes.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let noun = names.count == 1 ? "MCP server" : "MCP servers"
            let list = names.map { "'\($0)'" }.joined(separator: ", ")
            text += " \(noun) \(list)."
        }
        return text
    }

    private func volumeNote(for reference: AppPathReference) -> String {
        guard let volumeRoot = reference.possibleVolumeRoot else { return "" }
        if fileManager.fileExists(atPath: volumeRoot) { return "" }
        return " The volume '\(volumeRoot)' may not be mounted."
    }

    private func sortedLocations(_ locations: [String]) -> [String] {
        Array(Set(locations)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func notes(
        files: [DiscoveredConfigFile],
        usedHeuristic: Bool,
        skippedCount: Int = 0
    ) -> [String] {
        guard !files.isEmpty else { return [] }

        var notes: [String] = []
        let noun = files.count == 1 ? "configuration file" : "configuration files"
        notes.append("Inspected \(files.count) specified \(noun) for stored application paths in JSON, plist, and text settings. Only the files passed with --path were read.")
        if usedHeuristic {
            notes.append("Heuristic extraction of path-like strings is supported; MacBay does not confirm that a setting is currently in use or that an app was moved or deleted.")
        } else {
            notes.append("A reported path is a candidate only; MacBay does not confirm that an app was moved or that it is the same version.")
        }
        notes.append("Known MCP sections (mcp_servers in TOML, mcpServers in JSON) are read for command, args, and env string values; disabled servers are skipped.")
        notes.append("Path wildcards, template tokens, and the literal AppName.app placeholder are not checked as file references.")
        if skippedCount > 0 {
            let item = skippedCount == 1 ? "reference" : "references"
            notes.append("\(skippedCount) \(item) matched the skip policy above and were not counted as findings.")
        }
        return notes
    }

    private static func unreadableFinding(path: String, reason: String) -> DoctorFinding {
        unreadableFinding(name: URL(fileURLWithPath: path).lastPathComponent, paths: [path], reason: reason)
    }

    private static func unreadableFinding(name: String, paths: [String], reason: String) -> DoctorFinding {
        DoctorFinding(
            code: .externalConfigUnreadable,
            status: .unableToVerify,
            category: .externalReference,
            name: name,
            paths: paths,
            detail: "Configuration could not be read: \(reason)",
            recommendation: "Confirm whether this setting is currently in use, then inspect or restore \(paths.first ?? "the configuration") manually; MacBay does not change configuration files."
        )
    }

    private static func byteLimitDescription(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return "\(bytes / (1024 * 1024)) MiB"
        }
        return "\(bytes) bytes"
    }

    private static func isOrderedBefore(_ lhs: DoctorFinding, _ rhs: DoctorFinding) -> Bool {
        if lhs.code != rhs.code {
            return lhs.code.rawValue.localizedCaseInsensitiveCompare(rhs.code.rawValue) == .orderedAscending
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return (lhs.paths.first ?? "").localizedCaseInsensitiveCompare(rhs.paths.first ?? "") == .orderedAscending
    }
}
