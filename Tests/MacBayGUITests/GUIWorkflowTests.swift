import XCTest
import MacBayKit
@testable import MacBayGUI

final class GUIWorkflowTests: XCTestCase {
    private let request = GUIUpdateRequest(action: .begin, appPath: "/Applications/Example.app")

    @MainActor
    func testPreviewAndCancelNeverExecuteAndExpiredConfirmationIsIgnored() async throws {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let preview = try XCTUnwrap(store.actionPreview)
        await assertExecutions(fake, 0)
        store.dismissAction()
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        XCTAssertNil(store.actionPreview)
        await assertExecutions(fake, 0)
    }

    @MainActor
    func testConfirmationIsExplicitAndRefreshesAfterExecution() async throws {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let preview = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: false))
        await assertExecutions(fake, 0)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        await assertExecutions(fake, 1)
        XCTAssertTrue(try XCTUnwrap(store.actionResult).succeeded)
        await assertRefreshed(fake)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        await assertExecutions(fake, 1)
    }

    @MainActor
    func testFinishRequiresVendorAcknowledgmentAndCompatibilityAcknowledgment() async throws {
        let fake = WorkflowGUIService()
        await fake.setRiskRequired()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(GUIUpdateRequest(action: .finish, appPath: request.appPath))
        let preview = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true, acknowledgesRisks: true))
        await assertExecutions(fake, 0)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true,
                                                       acknowledgesRisks: true, vendorFinished: true))
        await assertExecutions(fake, 1)
    }

    @MainActor
    func testNavigationAndDiskRefreshInvalidateConfirmation() async throws {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let first = try XCTUnwrap(store.actionPreview)
        store.section = .updates
        await store.confirmAction(GUIActionConfirmation(previewID: first.id, reviewed: true))
        await store.previewUpdate(request)
        let second = try XCTUnwrap(store.actionPreview)
        await store.refresh()
        await store.confirmAction(GUIActionConfirmation(previewID: second.id, reviewed: true))
        await assertExecutions(fake, 0)
    }

    @MainActor
    func testFailureRefreshesStateAndRequiresNewPreviewBeforeRetry() async throws {
        let fake = WorkflowGUIService()
        await fake.setExecutionFailure(true)
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let first = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: first.id, reviewed: true))
        XCTAssertFalse(try XCTUnwrap(store.actionResult).succeeded)
        XCTAssertNil(store.actionPreview)
        await assertRefreshed(fake)
        store.dismissAction()
        await fake.setExecutionFailure(false)
        await store.previewUpdate(request)
        let fresh = try XCTUnwrap(store.actionPreview)
        XCTAssertNotEqual(first.id, fresh.id)
        await store.confirmAction(GUIActionConfirmation(previewID: fresh.id, reviewed: true))
        XCTAssertTrue(try XCTUnwrap(store.actionResult).succeeded)
        await assertExecutions(fake, 2)
    }

    @MainActor
    func testUnreadableUpdateStateDisablesNewWorkflows() async {
        let fake = WorkflowGUIService()
        await fake.setUpdatesFailure()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        XCTAssertNotNil(store.updateError)
        XCTAssertNil(store.actionPreview)
    }

    @MainActor
    func testLateWorkflowPreviewIsDiscardedAfterNavigation() async {
        let fake = WorkflowGUIService()
        await fake.delayPreview()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        let work = Task { await store.previewUpdate(request) }
        await fake.waitForPreview()
        store.section = .history
        await fake.releasePreview()
        await work.value
        XCTAssertNil(store.actionPreview)
        XCTAssertFalse(store.isPreparingPreview)
        await assertExecutions(fake, 0)
    }

    @MainActor
    func testExecutionCannotBeDismissedOrRepeatedAndLateProgressIsIgnored() async throws {
        let fake = WorkflowGUIService()
        await fake.delayExecution()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let preview = try XCTUnwrap(store.actionPreview)
        let confirmation = GUIActionConfirmation(previewID: preview.id, reviewed: true)
        let work = Task { await store.confirmAction(confirmation) }
        await fake.waitForExecution()
        XCTAssertTrue(store.isExecutingAction)
        store.dismissAction()
        XCTAssertTrue(store.showsActionSheet)
        await store.confirmAction(confirmation)
        await store.refresh()
        await fake.releaseExecution()
        await work.value
        await assertExecutions(fake, 1)
        XCTAssertFalse(store.isExecutingAction)
        let completedProgress = store.actionProgress.message
        await fake.emitLateProgress()
        await Task.yield()
        XCTAssertEqual(store.actionProgress.message, completedProgress)
    }

    @MainActor
    func testDemoWorkflowCanBePreparedAndFinishedWithoutHostWrites() async throws {
        let service = DemoGUIService()
        let store = GUIStore(service: service, isDemo: true, monitorVolumes: false)
        await store.start()
        await store.previewUpdate(GUIUpdateRequest(action: .begin, appPath: "/Applications/Visual Studio Code.app"))
        let preview = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true))
        let record = try XCTUnwrap(store.updateRecords.first { $0.appName == "Visual Studio Code.app" })
        XCTAssertEqual(record.phase, .awaitingUpdate)
        store.dismissAction()
        await store.previewUpdate(GUIUpdateRequest(action: .finish, appPath: record.sourcePath, expectedRecord: record))
        let finish = try XCTUnwrap(store.actionPreview)
        await store.confirmAction(GUIActionConfirmation(previewID: finish.id, reviewed: true, vendorFinished: true))
        XCTAssertFalse(store.updateRecords.contains { $0.appName == record.appName })
        XCTAssertTrue(try XCTUnwrap(store.actionResult).messages.contains { $0.contains("No real") })
    }

    @MainActor
    func testResultCannotBeDismissedUntilRefreshFinishesAndCompletionIsDeliveredOnce() async throws {
        let fake = WorkflowGUIService()
        let store = GUIStore(service: fake, monitorVolumes: false)
        await store.refresh()
        await store.previewUpdate(request)
        let preview = try XCTUnwrap(store.actionPreview)
        var completions = 0
        store.onActionCompleted = { _ in completions += 1 }
        await fake.delayNextScan()
        let work = Task { await store.confirmAction(GUIActionConfirmation(previewID: preview.id, reviewed: true)) }
        await fake.waitForScan()
        XCTAssertTrue(store.isFinalizingAction)
        store.dismissAction()
        XCTAssertNotNil(store.actionResult)
        XCTAssertFalse(store.canPrepareWorkflow)
        XCTAssertEqual(completions, 0)
        await fake.releaseScan()
        await work.value
        XCTAssertFalse(store.isFinalizingAction)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    private func assertExecutions(_ service: WorkflowGUIService, _ expected: Int,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let count = await service.executionCount()
        XCTAssertEqual(count, expected, file: file, line: line)
    }
    @MainActor
    private func assertRefreshed(_ service: WorkflowGUIService,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let count = await service.refreshCount()
        XCTAssertGreaterThan(count, 1, file: file, line: line)
    }
}

actor WorkflowGUIService: GUIServiceProtocol {
    private var holdsScan = false
    private var pendingScan: CheckedContinuation<Void, Never>?
    private var scanObserver: CheckedContinuation<Void, Never>?
    func delayNextScan() { holdsScan = true }
    func waitForScan() async {
        if pendingScan != nil { return }
        await withCheckedContinuation { scanObserver = $0 }
    }
    func releaseScan() { holdsScan = false; pendingScan?.resume(); pendingScan = nil }
    private var savedSetupCount = 0
    private var setupFails = false
    func failSetupSave() { setupFails = true }
    func setupSaveCount() -> Int { savedSetupCount }
    func setupChecks(volumePath: String?) -> GUISetupReport {
        GUISetupReport(volumePath: volumePath, checks: [], canSaveDefault: volumePath != nil)
    }
    func saveSetup(_ id: UUID) throws {
        if setupFails { throw GUIError.unavailable("Drive changed; check setup again.") }
        savedSetupCount += 1
    }
    private var executions = 0
    private var refreshes = 0
    private var riskRequired = false
    private var executionFails = false
    private var updatesFail = false
    private var holdsPreview = false
    private var holdsExecution = false
    private var pendingPreview: CheckedContinuation<Void, Never>?
    private var previewObserver: CheckedContinuation<Void, Never>?
    private var pendingExecution: CheckedContinuation<Void, Never>?
    private var executionObserver: CheckedContinuation<Void, Never>?
    private var lastProgress: (@Sendable (GUIActionProgress) -> Void)?
    func delayPreview() { holdsPreview = true }
    func delayExecution() { holdsExecution = true }
    func waitForPreview() async {
        if pendingPreview != nil { return }
        await withCheckedContinuation { previewObserver = $0 }
    }
    func releasePreview() { pendingPreview?.resume(); pendingPreview = nil }
    func waitForExecution() async {
        if pendingExecution != nil { return }
        await withCheckedContinuation { executionObserver = $0 }
    }
    func releaseExecution() { pendingExecution?.resume(); pendingExecution = nil }
    func emitLateProgress() { lastProgress?(GUIActionProgress("Late obsolete progress")) }
    func setRiskRequired() { riskRequired = true }
    func setExecutionFailure(_ value: Bool) { executionFails = value }
    func setUpdatesFailure() { updatesFail = true }
    func executionCount() -> Int { executions }
    func refreshCount() -> Int { refreshes }
    func status() -> StatusReport { refreshes += 1; return GUIExamples.status }
    func scan() async -> ScanReport {
        if holdsScan {
            await withCheckedContinuation {
                pendingScan = $0
                scanObserver?.resume()
                scanObserver = nil
            }
        }
        return GUIExamples.scan
    }
    func doctor() -> DoctorReport { GUIExamples.doctor }
    func history() -> [HistoryEntry] { [] }
    func caches() -> [PurgeItem] { [] }
    func updates() throws -> [UpdateWorkflowRecord] {
        if updatesFail { throw GUIError.unavailable("Unreadable update state") }
        return []
    }
    func recovery() -> GUIRecoverySnapshot { GUIRecoverySnapshot(items: []) }
    func previewRecovery(_ item: GUIRecoveryItem) -> GUIActionPreview {
        GUIActionPreview(kind: .repairRollback, detail: GUIPreview(title: "Rollback", subtitle: "", rows: []), confirmTitle: "Roll Back")
    }
    func previewUpdate(_ request: GUIUpdateRequest) async -> GUIActionPreview {
        if holdsPreview {
            await withCheckedContinuation {
                pendingPreview = $0
                previewObserver?.resume()
                previewObserver = nil
            }
        }
        return GUIActionPreview(kind: .update(request.action), detail: GUIPreview(title: "Update", subtitle: "", rows: []),
                         confirmTitle: "Execute", requiresRiskAcknowledgment: riskRequired)
    }
    func executeAction(_ confirmation: GUIActionConfirmation,
                       progress: @escaping @Sendable (GUIActionProgress) -> Void) async throws -> GUIActionResult {
        executions += 1
        lastProgress = progress
        progress(GUIActionProgress("Verifying…"))
        if holdsExecution {
            await withCheckedContinuation {
                pendingExecution = $0
                executionObserver?.resume()
                executionObserver = nil
            }
        }
        if executionFails { throw GUIError.unavailable("Signature verification failed; workflow preserved") }
        return GUIActionResult(succeeded: true, title: "Done", messages: [])
    }
    func discardAction(_ id: UUID) {}
    func previewApplication(_ app: GUIApplication, volumePath: String?) -> GUIActionPreview { GUIActionPreview(kind: .migration(.move), detail: GUIPreview(title: "", subtitle: "", rows: []), confirmTitle: "Move") }
    func previewCaches(_ items: [PurgeItem]) -> GUIActionPreview { GUIActionPreview(kind: .cleanup, detail: GUIPreview(title: "", subtitle: "", rows: []), confirmTitle: "Clean") }
    func previewXcode(volumePath: String) -> GUIPreview { GUIPreview(title: "", subtitle: "", rows: []) }
}
