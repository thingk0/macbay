import SwiftUI

struct GUIRecoveryCenterView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Review interrupted operations.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await store.refresh() } }.disabled(!store.canPrepareWorkflow)
                }
            }
            if let error = store.recoveryError {
                Section {
                    Label("Recovery state unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                } footer: {
                    Text("Refresh before retrying. An unavailable check does not mean there are no interrupted operations.")
                }
            } else if let snapshot = store.recoverySnapshot {
                if snapshot.items.isEmpty && snapshot.warnings.isEmpty {
                    Section {
                        Label("No interrupted operations found in the checked scope.", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                }
                if !snapshot.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(snapshot.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(GUIRecoverySource.allCases, id: \.self) { source in
                    let items = snapshot.items.filter { $0.source == source }
                    if !items.isEmpty {
                        Section(source.rawValue + " · " + String(items.count)) {
                            ForEach(items) { item in recoveryRow(item) }
                        }
                    }
                }
            } else {
                Section { ProgressView("Reading recovery state…").controlSize(.small) }
            }
            Section {
                if store.isPreparingPreview { ProgressView("Validating the recorded operation…").controlSize(.small) }
                Text("Supported actions always open a new preview.").foregroundStyle(.secondary)
            } footer: {
                Text("Browsing and cancelling change no application files.")
            }
        }.formStyle(.grouped)
    }

    private func recoveryRow(_ item: GUIRecoveryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.name).fontWeight(.medium)
                Spacer()
                GUIBadge(title: item.capability.actionTitle == nil ? "Manual guidance" : "Preview available", color: .orange)
            }
            if let phase = item.phase { Text("Recorded phase · " + phase).font(.caption).foregroundStyle(.secondary) }
            Text(item.detail)
            Text(item.guidance).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Affected Paths") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.paths, id: \.self) { path in
                        Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 8)
            }.font(.caption)
            if case .manual(let command) = item.capability, let command {
                Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
            if let actionTitle = item.capability.actionTitle {
                HStack {
                    Spacer()
                    Button(actionTitle) { Task { await store.previewRecovery(item) } }
                        .disabled(!store.canPrepareWorkflow)
                }
            }
        }.padding(.vertical, 3)
    }
}
