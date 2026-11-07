import AppKit
import MacBayKit
import SwiftUI

struct GUIMenuBarSettings: View {
    var includesVisibilityToggle = true
    @AppStorage(GUIMenuBarPreferences.enabledKey) private var enabled = true
    @AppStorage(GUIMenuBarPreferences.displayKey) private var display = GUIMenuBarDisplay.connected
    @AppStorage(GUIMenuBarPreferences.metricKey) private var metric = GUIMenuBarMetric.usedPercentage

    var body: some View {
        if includesVisibilityToggle { Toggle("Show storage in the menu bar", isOn: $enabled) }
        Group {
            Picker("Menu bar display", selection: $display) {
                ForEach(GUIMenuBarDisplay.allCases) { Text($0.title).tag($0) }
            }
            Picker("Show", selection: $metric) {
                ForEach(GUIMenuBarMetric.allCases) { Text($0.title).tag($0) }
            }
        }.disabled(!enabled)
    }
}

struct GUIMenuBarView: View {
    @ObservedObject var store: GUIStore
    let openWindow: () -> Void
    let openSettings: () -> Void
    @AppStorage("macbay.gui.appearance") private var appearance = "system"
    @AppStorage(GUIMenuBarPreferences.displayKey) private var display = GUIMenuBarDisplay.connected
    @AppStorage(GUIMenuBarPreferences.metricKey) private var metric = GUIMenuBarMetric.usedPercentage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: GUIMenuBarSnapshot {
        GUIMenuBarSnapshot(status: store.statusReport, selectedVolumePath: store.selectedVolumePath, error: store.statusError)
    }
    private var isMoving: Bool {
        guard store.isExecutingAction, let kind = store.actionPreview?.kind else { return false }
        if case .migration = kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MacBay").font(.headline)
                if store.isDemo { Text("Demo data").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Label(snapshot.connection, systemImage: snapshot.externalCapacity == nil ? "link.badge.plus" : "link")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.externalCapacity == nil ? "Available on your Mac" : "Available across both drives")
                    .font(.caption).foregroundStyle(.secondary)
                Text(snapshot.combinedCapacity?.availableText ?? "—")
                    .font(.title.weight(.medium)).monospacedDigit()
            }
            HStack(spacing: 12) {
                disk(name: snapshot.internalName, capacity: snapshot.internalCapacity, external: false)
                Group {
                    if isMoving && !reduceMotion { ProgressView().controlSize(.small) }
                    else { Image(systemName: snapshot.externalCapacity == nil ? "ellipsis" : "link").foregroundStyle(.secondary) }
                }.frame(width: 22)
                disk(name: snapshot.externalName, capacity: snapshot.externalCapacity, external: true)
            }
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if snapshot.internalCapacity != nil && snapshot.externalCapacity == nil {
                Text(snapshot.connection == "Choose a drive" ? "Choose a destination in MacBay to connect the second gauge."
                    : "Connect your external drive to see its current capacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.isExecutingAction {
                Label(store.actionProgress.message, systemImage: "arrow.right.arrow.left")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Capacity refreshes when the operation finishes.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Menu {
                    Picker("Display", selection: $display) {
                        ForEach(GUIMenuBarDisplay.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Values", selection: $metric) {
                        ForEach(GUIMenuBarMetric.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button("Settings…", action: openSettings)
                        .disabled(store.isExecutingAction || store.isSavingSetup || store.showsActionSheet)
                    Button("Quit MacBay") { NSApplication.shared.terminate(nil) }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Open MacBay", action: openWindow).guiButton()
            }
        }
        .padding(16).frame(width: 330)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }

    private func disk(name: String, capacity: GUIMenuBarCapacity?, external: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(name, systemImage: external ? "externaldrive" : "laptopcomputer")
                .font(.caption.weight(.medium)).lineLimit(1).help(name)
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(.primary.opacity(0.10), lineWidth: 3)
                    if let fraction = capacity?.usedFraction {
                        Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }.frame(width: 28, height: 28).accessibilityHidden(true)
                Text(capacity?.percentageText ?? "—").font(.system(size: 19, weight: .medium)).monospacedDigit()
            }
            Text(capacity.map { $0.availableText + " available" } ?? (external ? snapshot.connection : "Unavailable"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name + ", " + (capacity.map { $0.percentageText + " used, " + $0.availableText + " available" } ?? "Unavailable"))
    }
}
