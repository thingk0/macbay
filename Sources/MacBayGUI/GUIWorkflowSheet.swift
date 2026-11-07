import SwiftUI

struct GUIWorkflowSheet: View {
    @ObservedObject var store: GUIStore
    @State private var reviewed = false
    @State private var acknowledgesRisks = false
    @State private var vendorFinished = false
    @State private var confirmsCacheRemoval = false
    @State private var confirmsXcodeRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let result = store.actionResult, !store.isExecutingAction {
                Label(result.title, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold)).foregroundStyle(result.succeeded ? .green : .orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.callout).textSelection(.enabled)
                        }
                        ForEach(Array(Set(result.paths)).sorted(), id: \.self) { path in
                            GUIPathActions(path: path, demo: store.isDemo)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text(store.isFinalizingAction ? "Refreshing storage, Diagnostics, and History…" : "Workflow, Diagnostics, and History refreshed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if result.canOpenRecovery {
                        Button("Open Recovery Center") {
                            store.dismissAction()
                            store.section = .recovery
                        }.guiButton().disabled(store.isFinalizingAction)
                    }
                    Button("Done") { store.dismissAction() }.guiButton(prominent: true).keyboardShortcut(.defaultAction)
                        .disabled(store.isFinalizingAction)
                }
            } else if let preview = store.actionPreview {
                HStack {
                    GUIPageHeading(title: preview.detail.title, subtitle: preview.detail.subtitle)
                    GUIBadge(title: store.isDemo ? "Demo" : store.isExecutingAction ? "In Progress" : "Preview", color: .blue)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        GUIPanel {
                            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 13) {
                                ForEach(preview.detail.rows) { row in
                                    GridRow {
                                        Text(row.label).foregroundStyle(.secondary).frame(width: 145, alignment: .leading)
                                        Text(row.value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    }.font(.callout)
                                }
                            }
                        }
                        ForEach(Array(preview.detail.messages.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if store.isExecutingAction {
                    VStack(alignment: .leading, spacing: 9) {
                        if let fraction = store.actionProgress.fraction { ProgressView(value: fraction) }
                        else { ProgressView().controlSize(.small) }
                        Text(store.actionProgress.message).font(.callout)
                        Text("Keep MacBay open and the original drive connected until this finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if !preview.canExecute {
                        Label(preview.blockedReason ?? "Free enough space and review a new preview before continuing.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Toggle(store.isDemo ? "I reviewed this simulated action." : "I reviewed these paths and understand this action changes files.",
                           isOn: $reviewed)
                    if preview.requiresVendorFinished {
                        Toggle("The vendor update is complete and the app is closed.", isOn: $vendorFinished)
                    }
                    if preview.requiresRiskAcknowledgment {
                        Toggle("I accept the compatibility warnings and possible relocation prompts.", isOn: $acknowledgesRisks)
                    }
                    if preview.requiresCacheRemovalConfirmation {
                        Toggle("Remove these selected caches permanently. Apps can recreate them.", isOn: $confirmsCacheRemoval)
                    }
                    if preview.requiresXcodeRemovalConfirmation {
                        Toggle("Permanently remove the selected build data, caches, or unavailable simulators.", isOn: $confirmsXcodeRemoval)
                    }
                    HStack {
                        Button("Cancel") { store.dismissAction() }.guiButton().keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(store.isDemo ? "Simulate Action" : preview.confirmTitle) {
                            let confirmation = GUIActionConfirmation(previewID: preview.id, reviewed: reviewed,
                                acknowledgesRisks: acknowledgesRisks, vendorFinished: vendorFinished,
                                confirmsCacheRemoval: confirmsCacheRemoval, confirmsXcodeRemoval: confirmsXcodeRemoval)
                            Task { await store.confirmAction(confirmation) }
                        }
                        .guiButton(prominent: true).controlSize(.regular)
                        .disabled(!store.canConfirmAction || !preview.canExecute || !reviewed || (preview.requiresVendorFinished && !vendorFinished)
                                  || (preview.requiresRiskAcknowledgment && !acknowledgesRisks)
                                  || (preview.requiresCacheRemovalConfirmation && !confirmsCacheRemoval)
                                  || (preview.requiresXcodeRemovalConfirmation && !confirmsXcodeRemoval))
                    }
                }
            }
        }
        .font(.callout)
        .padding(20).frame(width: 680, height: 680)
        .interactiveDismissDisabled(store.isExecutingAction || store.isFinalizingAction)
        .onExitCommand { store.dismissAction() }
        .onChange(of: store.actionPreview?.id) { _ in
            reviewed = false
            acknowledgesRisks = false
            vendorFinished = false
            confirmsCacheRemoval = false
            confirmsXcodeRemoval = false
        }
    }
}
