import Foundation

public struct AppInspector: @unchecked Sendable {
    public static let relocationSignals = [
        "moveToApplicationsFolder",
        "isInApplicationsFolder",
        "startsWith(\"/Volumes/\")",
        "PFMoveToApplicationsFolder"
    ]

    private let fileManager: FileManager
    private let commandRunner: any CommandRunner

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunner = SystemCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    public func assess(bundleURL: URL) -> CompatibilityAssessment {
        let standardizedURL = bundleURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              standardizedURL.pathExtension.lowercased() == "app" else {
            return CompatibilityAssessment(
                grade: .blocked,
                reasons: ["Invalid or missing application bundle: \(standardizedURL.path)"],
                evidence: ["Path does not exist or is not an .app directory"]
            )
        }

        let infoPlistURL = standardizedURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let infoPlistData = try? Data(contentsOf: infoPlistURL),
              let infoPlist = (try? PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil)) as? [String: Any] else {
            return CompatibilityAssessment(
                grade: .blocked,
                reasons: ["Corrupted application bundle: missing or unreadable Info.plist (\(standardizedURL.path))"],
                evidence: ["Unable to load Contents/Info.plist"]
            )
        }

        var blockedReasons: [String] = []
        var blockedEvidence: [String] = []
        var popupRiskReasons: [String] = []
        var popupRiskEvidence: [String] = []

        // 1. System Extensions check
        let systemExtensionsURL = standardizedURL.appendingPathComponent("Contents/Library/SystemExtensions")
        if fileManager.fileExists(atPath: systemExtensionsURL.path) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: systemExtensionsURL.path)) ?? []
            if !entries.isEmpty {
                blockedReasons.append("Application contains system extensions")
                blockedEvidence.append("Contents/Library/SystemExtensions is present and non-empty")
            }
        }
        if infoPlist["NSSystemExtensionUsageDescription"] != nil {
            blockedReasons.append("Application declares system extension usage description")
            blockedEvidence.append("NSSystemExtensionUsageDescription found in Info.plist")
        }

        // 2. KEXT / DEXT check
        let extensionsURL = standardizedURL.appendingPathComponent("Contents/Extensions")
        if fileManager.fileExists(atPath: extensionsURL.path) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: extensionsURL.path)) ?? []
            if !entries.isEmpty {
                blockedReasons.append("Application contains kernel extensions")
                blockedEvidence.append("Contents/Extensions is present and non-empty")
            }
        }
        let driverExtensionsURL = standardizedURL.appendingPathComponent("Contents/Library/DriverExtensions")
        if fileManager.fileExists(atPath: driverExtensionsURL.path) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: driverExtensionsURL.path)) ?? []
            if !entries.isEmpty {
                blockedReasons.append("Application contains driver extensions")
                blockedEvidence.append("Contents/Library/DriverExtensions is present and non-empty")
            }
        }
        if infoPlist["OSKernelExtensionUsageDescription"] != nil {
            blockedReasons.append("Application declares kernel extension usage description")
            blockedEvidence.append("OSKernelExtensionUsageDescription found in Info.plist")
        }

        // 3. codesign entitlements check (e.g. com.apple.security.virtualization)
        do {
            let result = try commandRunner.run(
                "/usr/bin/codesign",
                arguments: ["-d", "--entitlements", "-", "--xml", standardizedURL.path]
            )
            if result.status == 0, !result.standardOutput.isEmpty,
               let xmlData = result.standardOutput.data(using: .utf8),
               let entitlements = (try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil)) as? [String: Any] {
                if entitlements["com.apple.security.virtualization"] as? Bool == true {
                    blockedReasons.append("Application requires virtualization entitlement")
                    blockedEvidence.append("com.apple.security.virtualization=true in codesign entitlements")
                }
            } else if result.status != 0 {
                // If codesign fails with non-zero, treat as inspection failure
                let details = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                blockedReasons.append("Code signature inspection failed for \(standardizedURL.path)")
                blockedEvidence.append(details.isEmpty ? "codesign exited with status \(result.status)" : details)
            }
        } catch {
            blockedReasons.append("Unable to inspect code signature entitlements: \(error.localizedDescription)")
            blockedEvidence.append("codesign command failed: \(error)")
        }

        // 4. Privileged helper declaration
        if let helpers = infoPlist["SMPrivilegedExecutables"] as? [String: Any], !helpers.isEmpty {
            popupRiskReasons.append("Application declares privileged helper tools")
            popupRiskEvidence.append("SMPrivilegedExecutables found in Info.plist")
        }
        let launchServicesURL = standardizedURL.appendingPathComponent("Contents/Library/LaunchServices")
        if fileManager.fileExists(atPath: launchServicesURL.path) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: launchServicesURL.path)) ?? []
            if !entries.isEmpty {
                popupRiskReasons.append("Application contains LaunchServices helper tools")
                popupRiskEvidence.append("Contents/Library/LaunchServices is present and non-empty")
            }
        }

        // 5. ASAR and Mach-O chunk inspection for relocation signals
        do {
            let foundSignals = try scanSignals(in: standardizedURL)
            if !foundSignals.isEmpty {
                popupRiskReasons.append("Application contains DMG relocation prompt code")
                popupRiskEvidence.append(contentsOf: foundSignals)
            }
        } catch {
            blockedReasons.append("Failed to scan bundle contents: \(error.localizedDescription)")
            blockedEvidence.append("I/O error during chunked signal scanning: \(error)")
        }

        if !blockedReasons.isEmpty {
            return CompatibilityAssessment(
                grade: .blocked,
                reasons: blockedReasons + popupRiskReasons,
                evidence: blockedEvidence + popupRiskEvidence
            )
        } else if !popupRiskReasons.isEmpty {
            return CompatibilityAssessment(
                grade: .popupRisk,
                reasons: popupRiskReasons,
                evidence: popupRiskEvidence
            )
        } else {
            return CompatibilityAssessment(
                grade: .safe,
                reasons: [],
                evidence: []
            )
        }
    }

    private func scanSignals(in bundleURL: URL) throws -> [String] {
        var evidence: [String] = []

        // Scan Mach-O binaries under Contents/MacOS
        let macosURL = bundleURL.appendingPathComponent("Contents/MacOS")
        if fileManager.fileExists(atPath: macosURL.path) {
            if let enumerator = fileManager.enumerator(
                at: macosURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                while let file = enumerator.nextObject() as? URL {
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    let signals = try Self.searchSignals(in: file, signals: Self.relocationSignals)
                    for signal in signals {
                        evidence.append("Found '\(signal)' in Mach-O binary \(file.lastPathComponent)")
                    }
                }
            }
        }

        // Scan ASAR files under Contents/Resources
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        if fileManager.fileExists(atPath: resourcesURL.path) {
            if let enumerator = fileManager.enumerator(
                at: resourcesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                while let file = enumerator.nextObject() as? URL {
                    if file.pathExtension.lowercased() == "asar" {
                        let signals = try Self.searchSignals(in: file, signals: Self.relocationSignals)
                        for signal in signals {
                            evidence.append("Found '\(signal)' in ASAR file \(file.lastPathComponent)")
                        }
                    }
                }
            }
        }

        return evidence
    }

    public static func searchSignals(
        in fileURL: URL,
        signals: [String],
        chunkSize: Int = 65536,
        overlapSize: Int = 256
    ) throws -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw MacBayError.pathMissing("Unable to open file for inspection: \(fileURL.path)")
        }
        defer { try? handle.close() }

        var foundSignals: Set<String> = []
        let signalDataList = signals.map { (signal: $0, data: Data($0.utf8)) }
        var previousOverlap = Data()

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var combined = previousOverlap
            combined.append(chunk)

            for (signal, sigData) in signalDataList {
                if !foundSignals.contains(signal), combined.range(of: sigData) != nil {
                    foundSignals.insert(signal)
                }
            }

            if foundSignals.count == signals.count {
                break
            }

            if chunk.count >= overlapSize {
                previousOverlap = chunk.suffix(overlapSize)
            } else {
                previousOverlap = chunk
            }
        }

        return Array(foundSignals).sorted()
    }
}
