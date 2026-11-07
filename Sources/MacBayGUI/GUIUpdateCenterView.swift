import MacBayKit
import SwiftUI

struct GUIUpdateCenterView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    GUISectionIcon(section: .updates)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prepare → Vendor update → Finish").fontWeight(.medium)
                        Text("Prepare restores the app locally. Use its built-in updater or official installer, quit the app, then preview Finish.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Refresh") { Task { await store.refresh() } }.disabled(!store.canPrepareWorkflow)
                }
            } footer: {
                Text("Every file-changing step needs your confirmation.")
            }
            if let error = store.updateError {
                Section {
                    Label("Update state unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                } footer: {
                    Text("Refresh before starting another workflow. Existing records are preserved.")
                }
            } else {
                Section("In Progress · \(store.updateRecords.count)") {
                    if store.updateRecords.isEmpty {
                        Text("No updates in progress. Choose a managed app below.").foregroundStyle(.secondary)
                    }
                    ForEach(store.updateRecords) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(record.appName, systemImage: "app").fontWeight(.medium)
                                Spacer()
                                GUIBadge(title: record.phase == .awaitingUpdate ? "Awaiting vendor update" : "Preparation interrupted", color: .orange)
                            }
                            Text(record.phase == .awaitingUpdate
                                ? "Complete the vendor update while the app is local, then close it before finishing."
                                : "Review the recorded state and resume preparation before running the vendor updater.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(record.sourcePath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Label(record.volumeName + " · Original drive", systemImage: "externaldrive")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if record.phase == .preparing {
                                    Button("Preview Resume…") { preview(.begin, record: record) }
                                } else {
                                    Button("Preview Finish…") { preview(.finish, record: record) }
                                }
                            }
                        }.padding(.vertical, 3).disabled(!store.canPrepareWorkflow)
                    }
                }
                Section("Managed Applications") {
                    if store.updateApplications.isEmpty {
                        Text(store.isScanning ? "Scanning managed applications…" : "No additional managed apps on connected drives.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.updateApplications) { app in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: "app").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.displayName).fontWeight(.medium)
                                    Text(app.externalPath ?? app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button("Preview Prepare…") {
                                    Task { await store.previewUpdate(GUIUpdateRequest(action: .begin, appPath: app.path)) }
                                }
                            }
                            if app.name == "Kiro CLI.app" {
                                HStack {
                                    Text("Checks, updates, and returns the app.").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Preview Managed Update…") {
                                        Task { await store.previewUpdate(GUIUpdateRequest(action: .managedKiro, appPath: app.path)) }
                                    }
                                }
                            }
                        }.padding(.vertical, 3).disabled(!store.canPrepareWorkflow)
                    }
                }
            }
            if store.isPreparingPreview {
                Section { ProgressView("Running shared safety checks…").controlSize(.small) }
            }
        }.formStyle(.grouped)
    }
    private func preview(_ action: AppUpdateAction, record: UpdateWorkflowRecord) {
        Task { await store.previewUpdate(GUIUpdateRequest(action: action, appPath: record.sourcePath, expectedRecord: record)) }
    }
}
