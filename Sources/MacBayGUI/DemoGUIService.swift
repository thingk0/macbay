import Foundation
import MacBayKit

/// Deterministic previews for UI evaluation without inspecting or changing the host filesystem.
public actor DemoGUIService: GUIServiceProtocol {
    private var workflowRecords = GUIExamples.updates
    private enum DemoAction { case update(GUIUpdateRequest), rollback, migration(ApplicationMigrationAction, String), cleanup([String]) }
    private var pendingAction: (GUIActionPreview, DemoAction)?
    private var movedPaths = Set(GUIExamples.scan.externalApplications.map(\.sourcePath))
    private var cleanedPaths = Set<String>()
    private var repairFinished = false
    public init() {}
    public func status() -> StatusReport { GUIExamples.status }
    public func scan() -> ScanReport {
        let base = GUIExamples.scan
        let restored = base.externalApplications.filter { !movedPaths.contains($0.sourcePath) }.map {
            AppCandidate(name: $0.name, path: $0.sourcePath, sizeBytes: $0.sizeBytes ?? 0,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .safe))
        }
        let moved = base.candidates.filter { $0.kind == .application && movedPaths.contains($0.path) }.map {
            ExternalApplication(name: $0.name, sourcePath: $0.path, destinationPath: "/Volumes/KLEVV/MacBay/Applications/" + $0.name,
                                sizeBytes: $0.sizeBytes, managementStatus: .macBay)
        }
        return ScanReport(generatedAt: base.generatedAt, minimumApplicationSizeBytes: base.minimumApplicationSizeBytes,
            candidates: base.candidates.filter { !movedPaths.contains($0.path) } + restored,
            externalApplications: base.externalApplications.filter { movedPaths.contains($0.sourcePath) } + moved)
    }
    public func doctor() -> DoctorReport { GUIExamples.doctor }
    public func history() -> [HistoryEntry] { GUIExamples.history }
    public func caches() -> [PurgeItem] { GUIExamples.caches.filter { !cleanedPaths.contains($0.id) } }
    public func updates() -> [UpdateWorkflowRecord] { workflowRecords }
    public func setupChecks(volumePath: String?) -> GUISetupReport {
        GUISetupReport(volumePath: volumePath,
            checks: [GUISetupCheck("Demo storage", "All setup checks are simulated. No host settings are saved.", passed: true)],
            canSaveDefault: volumePath != nil)
    }
    public func saveSetup(_ id: UUID) {}
    public func recovery() -> GUIRecoverySnapshot {
        let updates = GUIRecoveryReader(fileManager: .default).updateItems(workflowRecords)
        let repair = GUIRecoveryItem(id: "demo-repair", source: .repair, name: "Example.app", phase: "staged",
            detail: "A demo repair stopped after staging the new app.",
            paths: ["/Applications/Example.app", "/Volumes/KLEVV/MacBay/Applications/Example.app"],
            guidance: "Preview the recorded rollback. This demo never reads or changes real app files.",
            capability: .rollback(GUIExamples.repairRecord))
        let manual = GUIRecoveryItem(id: "demo-adopt", source: .adopt, name: "Sample.app", phase: "link_replaced",
            detail: "A demo adoption was interrupted.", paths: ["/Applications/Sample.app"],
            guidance: "Inspect the paths and review the CLI dry run before retrying adoption.",
            capability: .manual(command: "mb adopt 'Sample.app' --volume '/Volumes/KLEVV' --dry-run"))
        return GUIRecoverySnapshot(items: (repairFinished ? [] : [repair]) + updates + [manual])
    }
    public func previewRecovery(_ item: GUIRecoveryItem) throws -> GUIActionPreview {
        switch item.capability {
        case .update(let request): return try previewUpdate(request)
        case .manual: throw GUIError.unavailable("This demo item provides manual guidance only.")
        case .rollback:
            let preview = GUIActionPreview(kind: .repairRollback,
                detail: GUIPreview(title: "Roll Back Interrupted Repair", subtitle: "Sample data. No real files are changed.",
                    rows: item.paths.map { GUIInfoRow("Affected path", $0) },
                    messages: ["The live workflow revalidates its journal, original volume, file snapshots, signatures, and process locks."]),
                confirmTitle: "Simulate Rollback")
            pendingAction = (preview, .rollback)
            return preview
        }
    }
    public func previewUpdate(_ request: GUIUpdateRequest) throws -> GUIActionPreview {
        let existing = workflowRecords.first { $0.sourcePath == request.appPath }
        guard existing == request.expectedRecord else { throw GUIError.unavailable("Demo workflow changed. Refresh before retrying.") }
        guard request.action != .finish || existing != nil else { throw GUIError.unavailable("No demo workflow to finish.") }
        let preview = GUIActionPreview(kind: .update(request.action),
            detail: GUIPreview(title: request.action == .finish ? "Finish App Update" : "Prepare App Update",
                subtitle: "Sample data. This action is simulated and never changes real files.",
                rows: [GUIInfoRow("Application", URL(fileURLWithPath: request.appPath).lastPathComponent),
                       GUIInfoRow("Local path", request.appPath), GUIInfoRow("Original drive", "KLEVV SSD"),
                       GUIInfoRow("Copy size", "600 MB"), GUIInfoRow("Signature", "Demo verification")],
                messages: ["Prepare → Vendor update → Finish. Real workflows recheck paths, signatures, locks, and space."]),
            confirmTitle: "Simulate Action")
        pendingAction = (preview, .update(request))
        return preview
    }
    public func executeAction(_ confirmation: GUIActionConfirmation,
                              progress: @escaping @Sendable (GUIActionProgress) -> Void) throws -> GUIActionResult {
        guard let (preview, action) = pendingAction, preview.id == confirmation.previewID else {
            throw GUIError.unavailable("Demo preview expired.")
        }
        pendingAction = nil
        guard preview.accepts(confirmation) else {
            throw GUIError.unavailable("Confirm this simulated action first.")
        }
        progress(GUIActionProgress("Simulating the workflow…"))
        let request: GUIUpdateRequest
        switch action {
        case .rollback:
            repairFinished = true
            return GUIActionResult(succeeded: true, title: "Rollback simulation completed", messages: ["No real files were read or changed."])
        case .migration(let action, let path):
            if action == .move { movedPaths.insert(path) } else { movedPaths.remove(path) }
            return GUIActionResult(succeeded: true, title: "Migration simulation completed", messages: ["No real applications or files were changed."])
        case .cleanup(let paths):
            cleanedPaths.formUnion(paths)
            return GUIActionResult(succeeded: true, title: "Cleanup simulation completed", messages: ["No real caches were removed."])
        case .update(let value): request = value
        }
        if request.action == .begin {
            movedPaths.remove(request.appPath)
            let name = URL(fileURLWithPath: request.appPath).lastPathComponent
            workflowRecords.removeAll { $0.sourcePath == request.appPath }
            workflowRecords.append(UpdateWorkflowRecord(appName: name, sourcePath: request.appPath,
                externalPath: "/Volumes/KLEVV/MacBay/Applications/" + name, bundleIdentifier: "com.example.demo",
                originalVersion: "1.0", originalBuild: "100", volumePath: "/Volumes/KLEVV",
                volumeName: "KLEVV SSD", volumeUUID: "DEMO-VOLUME", phase: .awaitingUpdate))
        } else {
            workflowRecords.removeAll { $0.sourcePath == request.appPath }
            movedPaths.insert(request.appPath)
        }
        return GUIActionResult(succeeded: true, title: "Simulation completed",
            messages: ["No real applications, update settings, or files were changed.",
                       request.action == .begin ? "The demo workflow is ready for its vendor update." : "The demo app returned to its original drive."])
    }
    public func discardAction(_ id: UUID) { if pendingAction?.0.id == id { pendingAction = nil } }
    public func previewApplication(_ app: GUIApplication, volumePath: String?) throws -> GUIActionPreview {
        guard app.canPreview else { throw GUIError.unavailable("This application is not eligible for a preview.") }
        if app.name == "Slack.app" { throw GUIError.unavailable("Slack is running. Quit Slack and try again.") }
        guard app.isRestore || volumePath != nil else {
            throw GUIError.unavailable("Choose an external drive.")
        }
        let detail = GUIPreview(title: app.isRestore ? "Restore Preview" : "Move Preview",
            subtitle: "Sample data. No real files are read or changed.",
            rows: [GUIInfoRow("Application", app.displayName),
                   GUIInfoRow("Source", app.isRestore ? app.externalPath ?? app.path : app.path),
                   GUIInfoRow("Destination", app.isRestore ? app.path : (volumePath ?? "") + "/MacBay/Applications/" + app.name),
                   GUIInfoRow("Copy size", GUIFormat.bytes(app.sizeBytes)),
                   GUIInfoRow("Destination free", GUIFormat.bytes(app.isRestore ? GUIExamples.status.internalVolume.availableBytes : GUIExamples.status.externalVolumes[0].availableBytes))],
            messages: ["The original application path is preserved.", "App update compatibility requires separate verification."],
            needsReview: app.state == .review)
        let action: ApplicationMigrationAction = app.isRestore ? .restore : .move
        let preview = GUIActionPreview(kind: .migration(action), detail: detail, confirmTitle: "Simulate Migration",
                                       requiresRiskAcknowledgment: app.state == .review)
        pendingAction = (preview, .migration(action, app.path))
        return preview
    }
    public func previewCaches(_ items: [PurgeItem]) throws -> GUIActionPreview {
        guard !items.isEmpty, !items.contains(where: \.isRunning) else {
            throw GUIError.unavailable("Select caches from apps that are not running.")
        }
        let preview = GUIActionPreview(kind: .cleanup,
            detail: GUIPreview(title: "Cleanup Preview", subtitle: "Sample data. No caches will be deleted.",
                rows: items.map { GUIInfoRow($0.appName, $0.path + " · " + GUIFormat.bytes($0.sizeBytes)) },
                messages: ["Accounts, sessions, preferences, and databases are excluded."]),
            confirmTitle: "Simulate Cleanup")
        pendingAction = (preview, .cleanup(items.map(\.id)))
        return preview
    }
    public func previewXcode(volumePath: String) -> GUIPreview {
        GUIPreview(title: "Xcode Storage Preview", subtitle: "Sample data. No developer files will be moved.",
            rows: [GUIInfoRow("Destination drive", volumePath),
                   GUIInfoRow("iOS DeviceSupport", "18.4 GB"), GUIInfoRow("Archives", "10.2 GB")],
            messages: ["Xcode must be closed before a real operation.", "Original paths are preserved."])
    }
}

public enum GUIExamples {
    public static let repairRecord = RepairJournalRecord(id: "DEMO-REPAIR", appName: "Example.app",
        localPath: "/Applications/Example.app", externalPath: "/Volumes/KLEVV/MacBay/Applications/Example.app",
        backupPath: "/Volumes/KLEVV/MacBay/Backups/DEMO-REPAIR/Example.app",
        stagingPath: "/Volumes/KLEVV/MacBay/.operations/.staging-DEMO-REPAIR/Example.app",
        localBackupPath: "/Applications/.Example.app.macbay-local-backup-DEMO-REPAIR",
        volumePath: "/Volumes/KLEVV", phase: .staged, timestamp: "2026-11-06T01:24:00Z",
        originalManifestItem: DockedItem(name: "Example.app", sourcePath: "/Applications/Example.app",
            externalPath: "/Volumes/KLEVV/MacBay/Applications/Example.app", sizeBytes: 128, kind: .application, dockedAt: ""))
    public static let updates = [
        UpdateWorkflowRecord(appName: "Figma.app", sourcePath: "/Applications/Figma.app",
            externalPath: "/Volumes/KLEVV/MacBay/Applications/Figma.app", bundleIdentifier: "com.figma.Desktop",
            originalVersion: "125", originalBuild: "1250", volumePath: "/Volumes/KLEVV",
            volumeName: "KLEVV SSD", volumeUUID: "DEMO-VOLUME", startedAt: "2026-11-06T01:24:00Z", phase: .awaitingUpdate)
    ]
    public static let status = StatusReport(
        generatedAt: "2026-11-06T01:24:00Z",
        internalVolume: StorageVolume(name: "Macintosh HD", path: "/", isInternal: true,
                                     totalBytes: 512_000_000_000, availableBytes: 88_400_000_000),
        externalVolumes: [StorageVolume(name: "KLEVV SSD", path: "/Volumes/KLEVV", isInternal: false,
                                       totalBytes: 2_000_000_000_000, availableBytes: 1_128_400_000_000)],
        dockedItems: [
            DockedItem(name: "Visual Studio Code.app", sourcePath: "/Applications/Visual Studio Code.app",
                       externalPath: "/Volumes/KLEVV/MacBay/Applications/Visual Studio Code.app",
                       sizeBytes: 600_000_000, kind: .application, dockedAt: "2026-11-05T05:00:00Z"),
            DockedItem(name: "Android SDK", sourcePath: "/Users/demo/Library/Android/sdk",
                       externalPath: "/Volumes/KLEVV/MacBay/Data/Android/sdk",
                       sizeBytes: 11_800_000_000, kind: .directory, dockedAt: "2026-11-06T01:24:00Z")
        ])
    public static let scan = ScanReport(
        generatedAt: "2026-11-06T01:24:00Z", minimumApplicationSizeBytes: 200 * 1024 * 1024,
        candidates: [
            AppCandidate(name: "Xcode.app", path: "/Applications/Xcode.app", sizeBytes: 21_800_000_000,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .popupRisk, reasons: ["Review privileged helper tools and app update compatibility."])),
            AppCandidate(name: "Android Studio.app", path: "/Applications/Android Studio.app",
                         sizeBytes: 14_200_000_000, kind: .application, compatibility: CompatibilityAssessment(grade: .safe)),
            AppCandidate(name: "Blender.app", path: "/Applications/Blender.app", sizeBytes: 3_100_000_000,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .safe)),
            AppCandidate(name: "Docker.app", path: "/Applications/Docker.app", sizeBytes: 3_400_000_000,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .blocked, reasons: ["Virtualization components prevent relocation."])),
            AppCandidate(name: "Slack.app", path: "/Applications/Slack.app", sizeBytes: 1_000_000_000,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .safe)),
            AppCandidate(name: "Figma.app", path: "/Applications/Figma.app", sizeBytes: 900_000_000,
                         kind: .application, compatibility: CompatibilityAssessment(grade: .safe)),
            AppCandidate(name: "Xcode DeviceSupport", path: "/Users/demo/Library/Developer/Xcode/iOS DeviceSupport",
                         sizeBytes: 18_400_000_000, kind: .developerCache)
        ],
        externalApplications: [
            ExternalApplication(name: "Visual Studio Code.app", sourcePath: "/Applications/Visual Studio Code.app",
                                destinationPath: "/Volumes/KLEVV/MacBay/Applications/Visual Studio Code.app",
                                sizeBytes: 600_000_000, managementStatus: .macBay),
            ExternalApplication(name: "Kiro CLI.app", sourcePath: "/Applications/Kiro CLI.app",
                                destinationPath: "/Volumes/KLEVV/MacBay/Applications/Kiro CLI.app",
                                sizeBytes: 500_000_000, managementStatus: .macBay)
        ])
    public static let doctor = DoctorReport(
        generatedAt: "2026-11-06T01:24:00Z", volumes: [],
        findings: [DoctorFinding(code: .localDataDetected, status: .needsAttention, category: .applicationLink,
                                name: "Kiro CLI.app", paths: ["/Applications/Kiro CLI.app"],
                                detail: "A local app has reappeared alongside the recorded external copy.",
                                recommendation: "Compare both copies with mb repair before choosing which copy to keep.")],
        summary: DoctorSummary(checked: 9, healthy: 8, unmanaged: 0, needsAttention: 1, unableToVerify: 0),
        warnings: [], notes: [])
    public static let history = [
        HistoryEntry(timestamp: "2026-11-06T01:24:00Z", command: "move", subject: "Android SDK",
                     outcome: .success, detail: "Moved 11.8 GB to KLEVV SSD"),
        HistoryEntry(timestamp: "2026-11-05T05:00:00Z", command: "dock", subject: "Visual Studio Code.app",
                     outcome: .success)
    ]
    public static let caches = [
        PurgeItem(appName: "Google Chrome", path: "/Users/demo/Library/Caches/Google/Chrome/Code Cache",
                  category: .chromiumCache, sizeBytes: 3_800_000_000, isRunning: false),
        PurgeItem(appName: "Homebrew", path: "/Users/demo/Library/Caches/Homebrew",
                  category: .homebrewCache, sizeBytes: 2_700_000_000, isRunning: false),
        PurgeItem(appName: "Slack", path: "/Users/demo/Library/Application Support/Slack/CacheStorage",
                  category: .chromiumCache, sizeBytes: 800_000_000, isRunning: true)
    ]
}
