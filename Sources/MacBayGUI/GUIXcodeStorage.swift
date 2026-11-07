import Foundation
import MacBayKit

public struct GUIXcodeSelection: Equatable, Sendable {
    public enum DerivedDataAction: String, CaseIterable, Sendable {
        case keep = "Keep in Place"
        case move = "Move to External Drive"
        case clean = "Remove Build Data"
    }
    public var moveDeviceSupport = true
    public var moveArchives = true
    public var derivedData: DerivedDataAction = .keep
    public var cleanCaches = false
    public var deleteUnavailableSimulators = false
    public init() {}

    public var options: XcodeDoctorOptions {
        XcodeDoctorOptions(externalizeDeviceSupport: moveDeviceSupport, externalizeArchives: moveArchives,
            externalizeDerivedData: derivedData == .move, cleanDerivedData: derivedData == .clean,
            cleanCaches: cleanCaches, deleteUnavailableSimulators: deleteUnavailableSimulators)
    }
    public var hasActions: Bool { !options.actionDescriptions.isEmpty }
}

enum GUIXcodeWorkflow {
    static func preview(_ plan: XcodeStoragePlan, demo: Bool = false) -> GUIActionPreview {
        let migrations = [plan.report.deviceSupport, plan.report.archives, plan.report.derivedData].compactMap { $0 }
        var rows = [GUIInfoRow("Destination drive", plan.volumePath),
                    GUIInfoRow("Drive UUID", plan.volumeUUID ?? "Unavailable"),
                    GUIInfoRow("Copy size", GUIFormat.bytes(plan.requiredBytes)),
                    GUIInfoRow("Destination free", GUIFormat.bytes(plan.availableBytes))]
        for migration in migrations {
            rows += [GUIInfoRow(migration.name, migration.sourcePath),
                     GUIInfoRow("External path", migration.destinationPath + " · " + GUIFormat.bytes(migration.sizeBytes))]
        }
        if plan.options.deleteUnavailableSimulators {
            rows.append(GUIInfoRow("Unavailable simulators", plan.unavailableSimulatorIDs.isEmpty
                ? "None" : plan.unavailableSimulatorIDs.joined(separator: "\n")))
        }
        let cleanups = [plan.report.derivedDataCleanup, plan.report.cacheCleanup].compactMap { $0 }
        rows += cleanups.map { GUIInfoRow($0.command, $0.output) }
        let removesData = plan.options.cleanDerivedData || plan.options.cleanCaches || plan.options.deleteUnavailableSimulators
        let hasChanges = plan.requiredBytes > 0 || plan.report.freedBytes > 0 || !plan.unavailableSimulatorIDs.isEmpty
        return GUIActionPreview(kind: .xcode,
            detail: GUIPreview(title: "Review Xcode Storage",
                subtitle: demo ? "Sample data. This action never changes real developer files."
                    : "Only the selected actions below will run. Xcode must remain closed.",
                rows: rows, messages: plan.options.actionDescriptions + migrations.flatMap(\.messages)
                    + ["Moved folders keep working through their original paths. Keep the destination drive connected.",
                       "Paths, drive identity, available space, running processes, and selected simulator IDs are checked again before execution."]
                    + (removesData ? ["Selected cleanup removes files permanently. Archives are moved only when selected above."] : []),
                needsReview: plan.report.hasFailures),
            confirmTitle: "Apply Xcode Storage Changes", canExecute: hasChanges && !plan.report.hasFailures,
            requiresXcodeRemovalConfirmation: removesData,
            blockedReason: hasChanges ? nil : "No selected Xcode data needs changes. Choose different actions or review again after Xcode creates data.")
    }

    static func result(_ report: XcodeDoctorReport, recoveryRecords: [MoveOperationRecord] = []) -> GUIActionResult {
        let migrations = [report.deviceSupport, report.archives, report.derivedData].compactMap { $0 }
        let cleanups = [report.derivedDataCleanup, report.cacheCleanup, report.simulatorCleanup].compactMap { $0 }
        var messages: [String] = []
        var paths: [String] = []
        for migration in migrations {
            messages.append("\(migration.name): \(migration.destinationPath)")
            messages.append(contentsOf: migration.messages)
            paths.append(contentsOf: [migration.sourcePath, migration.destinationPath])
        }
        for cleanup in cleanups {
            let outcome = cleanup.succeeded ? "Completed" : "Needs attention"
            messages.append("\(cleanup.command): \(outcome)\n\(cleanup.output)")
        }
        if report.derivedDataCleanup != nil || report.cacheCleanup != nil {
            messages.append("Removed \(GUIFormat.bytes(report.freedBytes)) of logical build and cache data. APFS free-space changes can differ.")
        }
        for failure in report.failedActions {
            messages.append("\(failure.action): \(failure.reason)")
        }
        if !recoveryRecords.isEmpty {
            messages.append("An interrupted move preserved its data copies. Inspect all recorded paths in Recovery Center before retrying.")
        }
        for record in recoveryRecords {
            paths.append(contentsOf: [record.sourcePath, record.destinationPath])
            if let backup = record.backupPath { paths.append(backup) }
        }
        return GUIActionResult(succeeded: !report.hasFailures,
            title: report.hasFailures ? "Xcode storage needs attention" : "Xcode storage completed",
            messages: messages, paths: paths, canOpenRecovery: !recoveryRecords.isEmpty)
    }
}
