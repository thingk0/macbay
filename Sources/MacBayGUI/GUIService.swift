import Foundation
import MacBayKit

/// File mutations are restricted to explicitly previewed and confirmed workflow actions.
public protocol GUIServiceProtocol: Sendable {
    func status() async throws -> StatusReport
    func scan() async -> ScanReport
    func doctor() async throws -> DoctorReport
    func history() async -> [HistoryEntry]
    func caches() async -> [PurgeItem]
    func previewApplication(_ app: GUIApplication, volumePath: String?) async throws -> GUIActionPreview
    func previewCaches(_ items: [PurgeItem]) async throws -> GUIActionPreview
    func previewXcode(volumePath: String) async throws -> GUIPreview
    func updates() async throws -> [UpdateWorkflowRecord]
    func recovery() async throws -> GUIRecoverySnapshot
    func previewRecovery(_ item: GUIRecoveryItem) async throws -> GUIActionPreview
    func previewUpdate(_ request: GUIUpdateRequest) async throws -> GUIActionPreview
    func executeAction(_ confirmation: GUIActionConfirmation,
                       progress: @escaping @Sendable (GUIActionProgress) -> Void) async throws -> GUIActionResult
    func discardAction(_ id: UUID) async
    func setupChecks(volumePath: String?) async throws -> GUISetupReport
    func saveSetup(_ id: UUID) async throws
}

/// All synchronous filesystem work runs on this actor, away from the UI actor.
public actor LiveGUIService: GUIServiceProtocol {
    private let service: MacBayService
    private enum Prepared {
        case update(AppUpdatePlan), rollback(RepairRollbackPlan)
        case migration(ApplicationMigrationPlan), cleanup(CachePurgePlan)
    }
    private var pending: (preview: GUIActionPreview, work: Prepared)?
    private var setupPlan: (id: UUID, plan: DefaultVolumePlan)?
    public init(service: MacBayService = MacBayService()) { self.service = service }

    public func status() throws -> StatusReport { try service.status() }
    public func scan() -> ScanReport {
        var directories = [URL(fileURLWithPath: "/Applications")]
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: userApps.path) { directories.append(userApps) }
        return service.scan(applicationDirectories: directories)
    }
    public func doctor() throws -> DoctorReport { try service.doctor() }
    public func history() -> [HistoryEntry] { service.history(limit: 100) }
    public func caches() -> [PurgeItem] { service.scanPurge() }

    public func setupChecks(volumePath: String?) throws -> GUISetupReport {
        setupPlan = nil
        let manager = FileManager.default
        var checks = [
            GUISetupCheck("Applications access", "/Applications · Moves and restores require write access here. macOS permission errors stop the operation.",
                          passed: manager.isReadableFile(atPath: "/Applications") && manager.isWritableFile(atPath: "/Applications")),
            GUISetupCheck("Cache access", "Only whitelisted cache folders are scanned. Review any denied paths in the scan or operation result.",
                          passed: manager.isReadableFile(atPath: manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path))
        ]
        do {
            let doctor = try service.doctor()
            let attention = doctor.summary.needsAttention + doctor.summary.unableToVerify
            checks.append(GUISetupCheck("First diagnosis",
                doctor.summary.checked == 0 ? "No managed items were found in the current scope. Review Diagnostics after your first operation."
                    : "\(doctor.summary.checked) items checked · \(attention) need review. Open Diagnostics for details.",
                passed: attention == 0))
        } catch {
            checks.append(GUISetupCheck("First diagnosis unavailable", error.localizedDescription, passed: false))
        }
        guard let volumePath else {
            checks.insert(GUISetupCheck("External drive", "Connect an external APFS drive, or continue without saving a default.", passed: false), at: 0)
            return GUISetupReport(volumePath: nil, checks: checks, canSaveDefault: false)
        }
        let plan = try service.planDefaultVolume(volumePath: volumePath)
        var writablePath = MacBayPaths.externalRoot(on: URL(fileURLWithPath: plan.volume.path))
        while !manager.fileExists(atPath: writablePath.path), writablePath.path != "/" {
            writablePath.deleteLastPathComponent()
        }
        let writable = manager.isWritableFile(atPath: writablePath.path)
        checks.insert(GUISetupCheck("External APFS drive", plan.volume.name + " · " + plan.volume.path + " · "
            + GUIFormat.bytes(plan.volume.availableBytes) + " available", passed: writable), at: 0)
        let report = GUISetupReport(volumePath: volumePath, checks: checks, canSaveDefault: writable,
                                   previousDefault: plan.previousDefault.map { $0.name + " · " + $0.path })
        if writable { setupPlan = (report.id, plan) }
        return report
    }

    public func saveSetup(_ id: UUID) throws {
        guard let saved = setupPlan, saved.id == id else { throw GUIError.unavailable("Setup checks expired. Check the selected drive again.") }
        setupPlan = nil
        _ = try service.executeDefaultVolume(plan: saved.plan)
    }

    public func updates() throws -> [UpdateWorkflowRecord] { try service.updateStatus() }

    public func recovery() throws -> GUIRecoverySnapshot {
        let reader = GUIRecoveryReader(fileManager: .default)
        let doctor = try service.doctor()
        var items = reader.items(doctor: doctor, status: try service.status())
        var warnings = doctor.warnings
        do { items += reader.updateItems(try service.updateStatus()) }
        catch { warnings.append("Update records could not be read: " + error.localizedDescription) }
        var seen = Set<String>()
        return GUIRecoverySnapshot(items: items.filter { seen.insert($0.id).inserted }, warnings: warnings)
    }

    public func previewRecovery(_ item: GUIRecoveryItem) throws -> GUIActionPreview {
        switch item.capability {
        case .update(let request): return try previewUpdate(request)
        case .manual: throw GUIError.unavailable("This state requires the operation-specific manual guidance shown in Recovery Center.")
        case .rollback(let record):
            pending = nil
            let plan = try service.planRepairRollback(appName: record.appName, volumePath: record.volumePath)
            guard plan.record == record else {
                throw GUIError.unavailable("Repair journal changed. Refresh Recovery Center before previewing rollback.")
            }
            let preview = GUIActionPreview(kind: .repairRollback,
                detail: GUIPreview(title: "Roll Back Interrupted Repair", subtitle: "Restore the original copies using this repair journal.",
                    rows: [GUIInfoRow("Application", record.appName), GUIInfoRow("Recorded phase", record.phase.rawValue),
                           GUIInfoRow("Local app", record.localPath), GUIInfoRow("External app", record.externalPath),
                           GUIInfoRow("External backup", record.backupPath), GUIInfoRow("Staging", record.stagingPath),
                           GUIInfoRow("Local backup", record.localBackupPath), GUIInfoRow("Volume UUID", plan.volumeUUID),
                           GUIInfoRow("Signature and identity", "All rollback copies verified"),
                           GUIInfoRow("Additional copy space", "0 B · Existing copies are moved within their volumes")],
                    messages: ["Only the recorded repair rollback is supported. Inspecting or cancelling changes no application files.",
                               "The journal, all affected paths, app identities, process locks, and original volume are checked again under the operation lock."]),
                confirmTitle: "Roll Back Repair")
            pending = (preview, .rollback(plan))
            return preview
        }
    }

    public func previewUpdate(_ request: GUIUpdateRequest) throws -> GUIActionPreview {
        pending = nil
        let existing = try service.updateStatus().first {
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path ==
                URL(fileURLWithPath: request.appPath).standardizedFileURL.path
        }
        guard existing == request.expectedRecord else {
            throw GUIError.unavailable("Update workflow changed. Refresh the Update Center before retrying.")
        }
        let plan = try service.planAppUpdate(action: request.action, appPath: request.appPath)
        let report = plan.report
        let titles: (String, String)
        switch request.action {
        case .begin: titles = ("Prepare App for Update", "Restore App Locally")
        case .finish: titles = ("Finish App Update", "Return to Original Drive")
        case .managedKiro: titles = ("Managed Kiro CLI Update", "Run Managed Update")
        }
        var rows = [
            GUIInfoRow("Application", report.record.appName),
            GUIInfoRow("Bundle identifier", report.record.bundleIdentifier),
            GUIInfoRow("Current version", report.currentVersion ?? "Unknown"),
            GUIInfoRow("Current build", report.currentBuild ?? "Unknown"),
            GUIInfoRow("Original drive", report.record.volumeName),
            GUIInfoRow("Volume UUID", report.record.volumeUUID)
        ]
        var sufficient = true
        if let migration = report.migration {
            let destination = request.action == .finish ? plan.resolvedVolumePath : "/"
            let estimate = SpaceEstimator().estimate(copyBytes: migration.sizeBytes,
                destinationVolume: URL(fileURLWithPath: destination),
                internalFreedBytes: request.action == .finish ? migration.sizeBytes : nil)
            sufficient = estimate.isSufficient
            rows += [
                GUIInfoRow("Source", migration.sourcePath), GUIInfoRow("Destination", migration.destinationPath),
                GUIInfoRow("Copy size", GUIFormat.bytes(migration.sizeBytes)),
                GUIInfoRow("Destination free", GUIFormat.bytes(estimate.destinationAvailableBytes)),
                GUIInfoRow("Signature", "Verified by the shared migration engine")
            ]
            if let after = estimate.destinationFreeAfterCopyBytes {
                rows.append(GUIInfoRow("Estimated free after copy", after >= 0 ? GUIFormat.bytes(UInt64(after)) : "Insufficient space"))
            }
            if estimate.shortfallBytes > 0 { rows.append(GUIInfoRow("Space shortfall", GUIFormat.bytes(estimate.shortfallBytes))) }
        } else {
            rows += [GUIInfoRow("Local app path", report.record.sourcePath),
                     GUIInfoRow("External app path", report.record.externalPath)]
        }
        let preview = GUIActionPreview(kind: .update(request.action),
            detail: GUIPreview(title: titles.0, subtitle: "Review the exact app and original drive before changing files.",
                rows: rows, messages: report.messages + (report.migration?.messages ?? []),
                needsReview: plan.requiresForce || !sufficient),
            confirmTitle: titles.1, requiresRiskAcknowledgment: plan.requiresForce, canExecute: sufficient)
        pending = (preview, .update(plan))
        return preview
    }

    public func executeAction(_ confirmation: GUIActionConfirmation,
                              progress: @escaping @Sendable (GUIActionProgress) -> Void) throws -> GUIActionResult {
        guard let prepared = pending, prepared.preview.id == confirmation.previewID else {
            throw GUIError.unavailable("This preview expired. Review a fresh preview before retrying.")
        }
        pending = nil
        guard prepared.preview.accepts(confirmation) else {
            throw GUIError.unavailable("Review and explicitly confirm every required acknowledgment before continuing.")
        }
        progress(GUIActionProgress("Rechecking the preview…"))
        switch prepared.work {
        case .rollback(let plan):
            let result = try service.executeRepairRollback(plan: plan, progress: { progress(GUIActionProgress($0)) })
            return GUIActionResult(succeeded: true, title: "Repair rollback completed",
                messages: ["Inspect the refreshed Diagnostics before starting another operation."],
                paths: [result.localPath, result.externalPath])
        case .update(let plan):
            let report = try service.executeAppUpdate(plan: plan, acknowledgeRisks: confirmation.acknowledgesRisks,
                progress: { progress(GUIActionProgress($0)) })
            return GUIActionResult(succeeded: true,
                title: plan.action == .begin ? "Ready for the vendor update" : "Update workflow completed",
                messages: report.messages, paths: [report.record.sourcePath])
        case .migration(let plan):
            let result = try service.executeApplicationMigration(plan: plan, acknowledgeRisks: confirmation.acknowledgesRisks,
                progress: { progress(GUIActionProgress($0)) })
            return GUIActionResult(succeeded: true,
                title: plan.action == .move ? "Application moved" : "Application restored",
                messages: result.messages, paths: [plan.appPath, result.destinationPath])
        case .cleanup(let plan):
            progress(GUIActionProgress("Removing the selected disposable caches…"))
            let result = try service.executeCachePurge(plan: plan)
            let complete = result.failedItems.isEmpty && result.skippedItems.isEmpty
            return GUIActionResult(succeeded: complete,
                title: complete ? "Cleanup completed" : "Cleanup partially completed",
                messages: ["Removed " + GUIFormat.bytes(result.totalReclaimedBytes) + " of logical cache data. APFS free-space changes can differ."]
                    + result.messages.filter { !$0.contains("successfully") }
                    + result.failedItems.map { $0.path + ": " + $0.reason },
                canOpenRecovery: !complete)
        }
    }

    public func discardAction(_ id: UUID) {
        if pending?.preview.id == id { pending = nil }
        if setupPlan?.id == id { setupPlan = nil }
    }

    public func previewApplication(_ app: GUIApplication, volumePath: String?) throws -> GUIActionPreview {
        pending = nil
        guard app.canPreview else {
            throw GUIError.unavailable("This app cannot be moved or restored in its current state. Review Diagnostics.")
        }
        let action: ApplicationMigrationAction = app.isRestore ? .restore : .move
        let plan = try service.planApplicationMigration(action: action, appPath: app.path, volumePath: volumePath)
        let result = plan.report
        let estimate = SpaceEstimator().estimate(copyBytes: result.sizeBytes,
            destinationVolume: URL(fileURLWithPath: app.isRestore ? "/" : plan.volumePath),
            internalFreedBytes: app.isRestore ? nil : result.sizeBytes)
        var rows = [GUIInfoRow("Application", app.displayName), GUIInfoRow("Source", result.sourcePath),
                    GUIInfoRow("Destination", result.destinationPath), GUIInfoRow("Drive UUID", plan.volumeUUID),
                    GUIInfoRow("Copy size", GUIFormat.bytes(result.sizeBytes)),
                    GUIInfoRow("Destination free", GUIFormat.bytes(estimate.destinationAvailableBytes)),
                    GUIInfoRow("Signature", "Verified by the shared migration engine")]
        if let after = estimate.destinationFreeAfterCopyBytes {
            rows.append(GUIInfoRow("Estimated free after copy", after >= 0 ? GUIFormat.bytes(UInt64(after)) : "Insufficient space"))
        }
        if estimate.shortfallBytes > 0 { rows.append(GUIInfoRow("Space shortfall", GUIFormat.bytes(estimate.shortfallBytes))) }
        let preview = GUIActionPreview(kind: .migration(action),
            detail: GUIPreview(title: app.isRestore ? "Restore Application" : "Move Application",
                subtitle: "Review the application and drive before changing files.", rows: rows, messages: result.messages,
                needsReview: plan.requiresForce || !estimate.isSufficient),
            confirmTitle: app.isRestore ? "Restore Application" : "Move Application",
            requiresRiskAcknowledgment: plan.requiresForce, canExecute: estimate.isSufficient)
        pending = (preview, .migration(plan))
        return preview
    }

    public func previewCaches(_ items: [PurgeItem]) throws -> GUIActionPreview {
        pending = nil
        let plan = try service.planCachePurge(items: items)
        let preview = GUIActionPreview(kind: .cleanup,
            detail: GUIPreview(title: "Clean Selected Caches", subtitle: "Only these selected disposable caches will be removed.",
                rows: plan.items.map { GUIInfoRow($0.appName, $0.path + " · " + GUIFormat.bytes($0.sizeBytes)) }
                    + [GUIInfoRow("Logical cache size", GUIFormat.bytes(plan.items.reduce(0) { $0 + $1.sizeBytes }))],
                messages: ["Cache removal cannot be undone. Apps can recreate these caches.",
                           "Accounts, sessions, preferences, and databases are excluded. Running apps are checked again."]),
            confirmTitle: "Remove Selected Caches")
        pending = (preview, .cleanup(plan))
        return preview
    }

    public func previewXcode(volumePath: String) throws -> GUIPreview {
        let plan = try service.planXcode(volumePath: volumePath, options: XcodeDoctorOptions())
        let results = [plan.report.deviceSupport, plan.report.archives, plan.report.derivedData].compactMap { $0 }
        return GUIPreview(
            title: "Xcode Storage Preview", subtitle: "Review the shared Xcode planner before any operation.",
            rows: [GUIInfoRow("Destination drive", plan.volumePath),
                   GUIInfoRow("Copy size", GUIFormat.bytes(plan.requiredBytes)),
                   GUIInfoRow("Destination free", GUIFormat.bytes(plan.availableBytes))]
                + results.map { GUIInfoRow($0.name, $0.destinationPath + " · " + GUIFormat.bytes($0.sizeBytes)) }
                + [GUIInfoRow("Unavailable simulators", String(plan.unavailableSimulatorIDs.count))],
            messages: plan.options.actionDescriptions + results.flatMap(\.messages)
                + plan.report.failedActions.map { $0.action + ": " + $0.reason },
            needsReview: plan.xcodeRunning || plan.report.hasFailures
        )
    }
}
