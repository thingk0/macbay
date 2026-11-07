import Foundation
import MacBayKit
import SwiftUI

public struct GUISetupCheck: Identifiable, Sendable {
    public let title: String
    public let detail: String
    public let passed: Bool
    public var id: String { title }
    public init(_ title: String, _ detail: String, passed: Bool) {
        self.title = title; self.detail = detail; self.passed = passed
    }
}

public struct GUISetupReport: Identifiable, Sendable {
    public let id: UUID
    public let volumePath: String?
    public let checks: [GUISetupCheck]
    public let canSaveDefault: Bool
    public let previousDefault: String?
    public init(id: UUID = UUID(), volumePath: String?, checks: [GUISetupCheck],
                canSaveDefault: Bool, previousDefault: String? = nil) {
        self.id = id; self.volumePath = volumePath; self.checks = checks
        self.canSaveDefault = canSaveDefault; self.previousDefault = previousDefault
    }
}

public extension GUIServiceProtocol {
    func setupChecks(volumePath: String?) async throws -> GUISetupReport {
        GUISetupReport(volumePath: volumePath, checks: [], canSaveDefault: false)
    }
    func saveSetup(_ id: UUID) async throws { throw GUIError.unavailable("Drive setup is unavailable in this service.") }
}

struct GUISetupView: View {
    @ObservedObject var store: GUIStore
    @AppStorage("macbay.gui.onboardingCompleted") private var completed = false
    @State private var saveDefault = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GUIPageHeading(title: "Set Up MacBay", subtitle: "Choose your storage and review access before your first operation.")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GUIPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Your external drive", systemImage: "externaldrive").font(.headline)
                            GUIVolumePicker(store: store)
                            Text("Only writable external APFS drives are listed. Each operation checks the drive and space again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if store.isCheckingSetup { ProgressView("Checking storage and access…") }
                    if let report = store.setupReport {
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(check.passed ? .green : .orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(check.title).font(.callout.weight(.semibold))
                                    Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        if let previous = report.previousDefault {
                            Text("Saved default: " + previous).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Save the selected drive as my default", isOn: $saveDefault)
                            .disabled(report.volumePath == nil)
                        Text("Saving replaces the previous default only after you finish setup. No applications are moved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.setupError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                    Text("MacBay does not need to stay open after completed operations. Keep it open while files are being changed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Set Up Later") {
                    completed = true
                    store.dismissSetup()
                }.guiButton().disabled(store.isSavingSetup).keyboardShortcut(.cancelAction)
                Button("Check Again") { Task { await store.checkSetup() } }.guiButton().disabled(store.isCheckingSetup || store.isSavingSetup)
                Spacer()
                Button("Finish Setup") {
                    Task {
                        if await store.finishSetup(saveDefault: saveDefault) { completed = true }
                    }
                }
                .guiButton(prominent: true).controlSize(.regular)
                .disabled(store.isCheckingSetup || store.isSavingSetup || store.setupReport == nil
                          || (saveDefault && store.setupReport?.canSaveDefault != true))
            }
        }
        .padding(20).frame(width: 640, height: 640)
        .interactiveDismissDisabled(store.isSavingSetup)
        .task { saveDefault = store.selectedVolumePath != nil; await store.checkSetup() }
        .onChange(of: store.selectedVolumePath) { path in
            saveDefault = path != nil
            Task { await store.checkSetup() }
        }
    }
}
