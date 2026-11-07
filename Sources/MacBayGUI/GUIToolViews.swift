import MacBayKit
import SwiftUI

struct GUIDeveloperView: View {
    @ObservedObject var store: GUIStore
    private var candidates: [AppCandidate] { store.scanReport?.candidates.filter { $0.kind == .developerCache } ?? [] }
    private var managed: [DockedItem] { store.statusReport?.dockedItems.filter { $0.kind != .application } ?? [] }
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    GUISectionIcon(section: .developer)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Xcode Storage").fontWeight(.medium)
                        Text("Choose what to move or clean, then review the affected paths.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GUIVolumePicker(store: store)
            }
            Section {
                Toggle("iOS DeviceSupport", isOn: $store.xcodeSelection.moveDeviceSupport)
                Toggle("Archives", isOn: $store.xcodeSelection.moveArchives)
                Picker("Derived Data", selection: $store.xcodeSelection.derivedData) {
                    ForEach(GUIXcodeSelection.DerivedDataAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
            } header: {
                Text("Move to External Drive")
            } footer: {
                Text("Moved folders keep their original paths through links. The external drive must remain connected.")
            }
            Section {
                Toggle("Remove Xcode and simulator caches", isOn: $store.xcodeSelection.cleanCaches)
                Toggle("Delete unavailable simulators", isOn: $store.xcodeSelection.deleteUnavailableSimulators)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Cleanup permanently removes the selected data and requires a separate confirmation. Build data and caches can be recreated.")
            }
            Section {
                HStack {
                    if store.isPreparingPreview { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Review Changes…") { Task { await store.previewXcode() } }
                        .disabled(store.selectedVolume == nil || !store.xcodeSelection.hasActions || !store.canPrepareWorkflow)
                }
            } footer: {
                Text("Quit Xcode before reviewing or applying changes.")
            }
            Section("Discovered Developer Data") {
                if candidates.isEmpty {
                    Text(store.isScanning ? "Scanning developer data…" : "No developer cache candidates found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    GUIDataRow(name: candidate.name, detail: candidate.path, size: candidate.sizeBytes, symbol: "folder")
                }
            }
            Section("Managed Data") {
                if managed.isEmpty { Text("No managed developer data on connected volumes.").foregroundStyle(.secondary) }
                ForEach(managed) { item in
                    GUIDataRow(name: item.name, detail: item.externalPath, size: item.sizeBytes, symbol: "link")
                }
            }
        }.formStyle(.grouped).disabled(store.isPerformingMutation)
    }
}

struct GUICleanupView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Review caches that apps can recreate.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Again") { Task { await store.scanCaches() } }.disabled(store.isScanningCaches)
                }
            }
            Section {
                if store.isScanningCaches {
                    ProgressView("Scanning disposable caches…").controlSize(.small)
                } else if store.cacheItems.isEmpty {
                    Text("No disposable caches found.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.cacheItems) { item in
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { store.selectedCacheIDs.contains(item.id) },
                                set: { selected in
                                    if selected { store.selectedCacheIDs.insert(item.id) }
                                    else { store.selectedCacheIDs.remove(item.id) }
                                }
                            )) { Text("Select " + item.appName) }.labelsHidden().toggleStyle(.checkbox)
                                .disabled(item.isRunning).accessibilityLabel("Select " + item.appName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.appName).fontWeight(.medium)
                                Text(item.category.displayName).font(.caption).foregroundStyle(.secondary)
                                Text(item.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                            }
                            Spacer()
                            if item.isRunning { GUIBadge(title: "Running · Skipped", color: .orange) }
                            Text(GUIFormat.bytes(item.sizeBytes)).font(.caption).monospacedDigit()
                        }.padding(.vertical, 3)
                    }
                }
            } header: {
                Text("Disposable Caches")
            } footer: {
                Text("Accounts, sign-in sessions, preferences, and databases are excluded.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(store.selectedCaches.count) selected · \(GUIFormat.bytes(store.selectedCaches.reduce(0) { $0 + $1.sizeBytes }))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Preview Cleanup…") { Task { await store.previewCleanup() } }
                    .guiButton(prominent: true)
                    .disabled(store.selectedCaches.isEmpty || store.isPreparingPreview || store.isScanningCaches)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct GUIDiagnosticsView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Check managed files, links, and operation records.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { Task { await store.refresh() } }.disabled(store.isRefreshing)
                }
            }
            if let error = store.doctorError {
                Section {
                    Label("Unable to verify storage health", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                }
            } else if let report = store.doctorReport {
                Section { summary(report) }
                Section("Checks") {
                    LabeledContent("Checked", value: String(report.summary.checked))
                    LabeledContent("Healthy", value: String(report.summary.healthy))
                    LabeledContent("Needs attention", value: String(report.summary.needsAttention))
                    LabeledContent("Unable to verify", value: String(report.summary.unableToVerify))
                }
                let findings = report.findings.filter { $0.status != .healthy }
                if !findings.isEmpty {
                    Section("Findings") {
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(finding.name, systemImage: finding.code == .incompleteOperation ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                                        .fontWeight(.medium)
                                    Spacer()
                                    GUIBadge(title: finding.status == .needsAttention ? "Needs attention" : "Unable to verify", color: .orange)
                                }
                                Text(finding.detail)
                                ForEach(finding.paths, id: \.self) { path in
                                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Text(finding.recommendation).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                if !report.notes.isEmpty {
                    Section {
                        DisclosureGroup("Scope & Details") {
                            ForEach(report.notes, id: \.self) { note in
                                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !report.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(report.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
            } else {
                Section { ProgressView("Checking managed storage…").controlSize(.small) }
            }
            Section {
                Button("Open Recovery Center…") { store.section = .recovery }
            } footer: {
                Text("Diagnostics are read-only. Review supported actions in Recovery Center.")
            }
        }.formStyle(.grouped)
    }

    private func summary(_ report: DoctorReport) -> some View {
        let attention = report.summary.needsAttention + report.summary.unableToVerify
        let checked = report.summary.checked
        let healthy = checked > 0 && attention == 0
        let color: Color = healthy ? .green : checked == 0 ? .blue : .orange
        return HStack(spacing: 10) {
            Image(systemName: healthy ? "checkmark.shield.fill" : checked == 0 ? "externaldrive" : "exclamationmark.shield.fill")
                .font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(healthy ? "All checks passed." : checked == 0 ? "Ready for your first check." : "A few items need a closer look.")
                    .fontWeight(.medium)
                Text(checked == 0 ? "No managed items were found in the current scope." : "\(checked) items checked across the current storage scope.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

struct GUIHistoryView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                if store.historyEntries.isEmpty {
                    Text("No recorded operations. Dry-run previews do not create history entries.").foregroundStyle(.secondary)
                }
                ForEach(Array(store.historyEntries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.outcome == .success ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(entry.outcome == .success ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.subject).fontWeight(.medium)
                            Text(entry.command).font(.caption).foregroundStyle(.secondary)
                            if let detail = entry.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(GUIFormat.date(entry.timestamp)).font(.caption).foregroundStyle(.secondary)
                            GUIBadge(title: entry.outcome.rawValue.capitalized, color: entry.outcome == .success ? .green : .orange)
                        }
                    }.padding(.vertical, 3)
                }
            } footer: {
                Text("History is a reference log. Storage health comes from Diagnostics.")
            }
        }.formStyle(.grouped)
    }
}

private struct GUIDataRow: View {
    let name: String
    let detail: String
    let size: UInt64
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Text(GUIFormat.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, 3)
    }
}
