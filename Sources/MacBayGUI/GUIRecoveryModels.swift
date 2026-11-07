import Foundation
import MacBayKit

public enum GUIRecoverySource: String, CaseIterable, Sendable {
    case repair = "Repair", update = "Updates", adopt = "Adoption", move = "Move", restore = "Restore", unknown = "Manual Review"
}

public enum GUIRecoveryCapability: Equatable, Sendable {
    case rollback(RepairJournalRecord)
    case update(GUIUpdateRequest)
    case manual(command: String?)
    public var actionTitle: String? {
        switch self {
        case .rollback: return "Preview Rollback"
        case .update(let request): return request.action == .begin ? "Preview Resume" : "Preview Finish"
        case .manual: return nil
        }
    }
}

public struct GUIRecoveryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: GUIRecoverySource
    public let name: String
    public let phase: String?
    public let detail: String
    public let paths: [String]
    public let guidance: String
    public let capability: GUIRecoveryCapability
    public init(id: String, source: GUIRecoverySource, name: String, phase: String? = nil, detail: String,
                paths: [String], guidance: String, capability: GUIRecoveryCapability) {
        self.id = id; self.source = source; self.name = name; self.phase = phase; self.detail = detail
        self.paths = paths; self.guidance = guidance; self.capability = capability
    }
}

public struct GUIRecoverySnapshot: Sendable {
    public let items: [GUIRecoveryItem]
    public let warnings: [String]
    public init(items: [GUIRecoveryItem], warnings: [String] = []) { self.items = items; self.warnings = warnings }
}

/// Reads known journal types; never infers a generic rollback from an error message.
struct GUIRecoveryReader {
    let fileManager: FileManager
    func items(doctor: DoctorReport, status: StatusReport) -> [GUIRecoveryItem] {
        doctor.findings.filter { $0.code == .incompleteOperation }.map { finding in
            let volumes = status.externalVolumes.filter { volume in
                finding.paths.dropFirst().contains { $0.hasPrefix(volume.path + "/") }
            }
            guard volumes.count == 1, let volume = volumes.first, finding.paths.count >= 2 else {
                return manual(finding, guidance: "Reconnect the recorded volume, refresh, and inspect the reported paths. " + finding.recommendation)
            }
            let url = URL(fileURLWithPath: volume.path)
            func same(_ left: String, _ right: String) -> Bool {
                URL(fileURLWithPath: left).standardizedFileURL.path == URL(fileURLWithPath: right).standardizedFileURL.path
            }
            var matches: [GUIRecoveryItem] = []
            if let record = DarwinRepairJournal(fileManager: fileManager).load(appName: finding.name, on: url),
               record.phase != .completed, record.schemaVersion == 1, same(record.volumePath, volume.path),
               same(record.localPath, finding.paths[0]), same(record.externalPath, finding.paths[1]) {
                matches.append(GUIRecoveryItem(id: "repair|" + volume.path + "|" + record.id,
                    source: .repair, name: record.appName, phase: record.phase.rawValue, detail: finding.detail,
                    paths: [record.localPath, record.externalPath, record.backupPath, record.stagingPath, record.localBackupPath],
                    guidance: "Review the recorded repair rollback. MacBay verifies the journal, app copies, running processes, and original volume again before execution.",
                    capability: .rollback(record)))
            }
            if let record = OperationJournal(fileManager: fileManager).load(for: finding.name, on: url),
               record.phase != .completed, same(record.volumePath, volume.path),
               same(record.sourcePath, finding.paths[0]), same(record.targetExternalPath, finding.paths[1]) {
                matches.append(GUIRecoveryItem(id: "adopt|" + volume.path + "|" + record.id,
                    source: .adopt, name: record.appName, phase: record.phase.rawValue, detail: finding.detail,
                    paths: [record.sourcePath, record.originalExternalPath, record.targetExternalPath],
                    guidance: "Adoption recovery uses its existing CLI workflow. Inspect the paths and review this dry run before retrying without --dry-run.",
                    capability: .manual(command: "mb adopt " + quote(record.sourcePath) + " --volume " + quote(volume.path) + " --dry-run")))
            }
            for record in OperationJournal(fileManager: fileManager).listIncompleteMoves(on: url) where
                same(record.volumePath, volume.path) && same(record.sourcePath, finding.paths[0]) && same(record.destinationPath, finding.paths[1]) {
                let source: GUIRecoverySource = record.kind == .move ? .move : .restore
                let command: String
                let isXcodeMove = record.destinationPath.hasPrefix(MacBayPaths.xcodeRoot(on: url).path + "/")
                if record.kind == .move, record.phase == .linkSwapped || record.phase == .manifestSaved || isXcodeMove {
                    command = "mb doctor --volume " + quote(volume.path) + " --fix --dry-run"
                } else if record.kind == .move {
                    command = "mb move " + quote(record.sourcePath) + " --volume " + quote(volume.path) + " --dry-run"
                } else { command = "mb unmove " + quote(record.sourcePath) + " --dry-run" }
                matches.append(GUIRecoveryItem(id: source.rawValue + "|" + volume.path + "|" + record.id,
                    source: source, name: record.name, phase: record.phase.rawValue, detail: finding.detail,
                    paths: [record.sourcePath, record.destinationPath] + [record.backupPath].compactMap { $0 },
                    guidance: "Inspect every recorded path, including any remaining backup. A backup may be incomplete; preserve the complete destination. Review the operation-specific CLI dry run before deciding how to continue.",
                    capability: .manual(command: command)))
            }
            guard matches.count == 1, let matched = matches.first else {
                return manual(finding, guidance: "No unique supported journal matches this finding. " + finding.recommendation)
            }
            return matched
        }
    }
    func updateItems(_ records: [UpdateWorkflowRecord]) -> [GUIRecoveryItem] {
        records.map { record in
            GUIRecoveryItem(id: "update|" + record.sourcePath, source: .update, name: record.appName,
                phase: record.phase.rawValue,
                detail: record.phase == .preparing ? "Update preparation did not finish." : "The workflow is waiting for the vendor update to finish.",
                paths: [record.sourcePath, record.externalPath],
                guidance: record.phase == .preparing
                    ? "Preview Resume to complete preparation. Then run the vendor updater while the app is local."
                    : "Complete the vendor update, quit the app, and preview Finish. The original drive is checked by UUID.",
                capability: .update(GUIUpdateRequest(action: record.phase == .preparing ? .begin : .finish,
                                                   appPath: record.sourcePath, expectedRecord: record)))
        }
    }
    private func manual(_ finding: DoctorFinding, guidance: String) -> GUIRecoveryItem {
        GUIRecoveryItem(id: "unknown|" + finding.id, source: .unknown, name: finding.name,
            detail: finding.detail, paths: finding.paths, guidance: guidance, capability: .manual(command: nil))
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
