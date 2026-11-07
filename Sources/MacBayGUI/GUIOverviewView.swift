import MacBayKit
import SwiftUI

struct GUIOverviewView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Form {
            Section {
                if let error = store.statusError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Unable to read disk status", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.caption).textSelection(.enabled)
                    }
                } else if let status = store.statusReport {
                    GUIDiskUsageRow(volume: status.internalVolume, external: false)
                    if let volume = store.selectedVolume {
                        GUIDiskUsageRow(volume: volume, external: true)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("External storage", systemImage: "externaldrive")
                            GUIVolumePicker(store: store)
                            Text(status.externalVolumes.isEmpty ? "Connect an external APFS drive to get started." : "Choose the drive to use with your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                } else {
                    ProgressView("Reading storage…").controlSize(.small)
                }
            } header: {
                Label(store.selectedVolume == nil ? "Storage" : "Connected Storage", systemImage: "link")
            }

            Section("Recommendations") {
                suggestion(.applications, detail: "Review apps to move or restore.",
                           size: store.hasScanned ? GUIFormat.bytes(store.moveCandidateBytes) + " estimated" : nil)
                suggestion(.developer, detail: "Xcode storage and development data.", size: nil)
                suggestion(.cleanup, detail: "Review caches that apps can recreate.",
                           size: store.hasScannedCaches ? GUIFormat.bytes(store.cacheItems.filter { !$0.isRunning }.reduce(0) { $0 + $1.sizeBytes }) : nil)
            }

            Section {
                if store.historyEntries.isEmpty {
                    Text("No recorded operations yet. Previews do not add history entries.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.historyEntries.prefix(2).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.outcome == .success ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(entry.outcome == .success ? .green : .orange)
                            Text(entry.subject).lineLimit(1)
                            Spacer()
                            Text(GUIFormat.date(entry.timestamp)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            } header: {
                HStack {
                    Text("Recent Activity")
                    Spacer()
                    Button("View All") { store.section = .history }.buttonStyle(.link)
                }
            }

            if !store.warnings.isEmpty {
                Section {
                    DisclosureGroup("Warnings (\(store.warnings.count))") {
                        ForEach(store.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func suggestion(_ section: GUISection, detail: String, size: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            GUISectionIcon(section: section)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let size { Text(size).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            Button("Show…") { store.section = section }.controlSize(.small)
                .accessibilityLabel("Show " + section.title)
        }.padding(.vertical, 3)
    }
}

private struct GUIDiskUsageRow: View {
    let volume: StorageVolume
    let external: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(volume.name, systemImage: external ? "externaldrive" : "internaldrive")
                    .fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                Text(GUIFormat.bytes(volume.usedBytes) + " of " + GUIFormat.bytes(volume.totalBytes) + " used")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(volume.usedBytes), total: Double(max(1, volume.totalBytes)))
                .tint(external ? .blue : .gray)
                .accessibilityLabel(volume.name + " used storage")
            HStack {
                Text(external ? "External · APFS" : "This Mac")
                Spacer()
                Text(GUIFormat.bytes(volume.availableBytes) + " available").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
