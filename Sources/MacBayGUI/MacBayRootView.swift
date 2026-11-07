import AppKit
import MacBayKit
import SwiftUI

/// SwiftUI embedding uses the same native split controller as the app window.
public struct MacBayRootView: View {
    private let store: GUIStore
    private let defaults: UserDefaults
    public init(store: GUIStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }
    public var body: some View {
        GUIMainWindowHost(store: store, defaults: defaults)
            .id(ObjectIdentifier(store))
            .frame(minWidth: GUIMainWindowController.minimumContentSize.width,
                   minHeight: GUIMainWindowController.minimumContentSize.height)
    }
}

private struct GUIMainWindowHost: NSViewControllerRepresentable {
    let store: GUIStore
    let defaults: UserDefaults
    func makeNSViewController(context: Context) -> GUIMainSplitViewController {
        GUIMainSplitViewController(store: store, defaults: defaults)
    }
    func updateNSViewController(_ controller: GUIMainSplitViewController, context: Context) {}
}

struct GUIMainSidebarView: View {
    @ObservedObject var store: GUIStore
    @AppStorage("macbay.gui.appearance") private var appearance = "system"
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            GUISearchField(text: $search, focusRequest: 0, placeholder: "Search MacBay")
                .frame(height: 26).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            List(selection: Binding<GUISection?>(get: { store.section }, set: { if let section = $0 { store.section = section } })) {
                Section("Storage") {
                    ForEach(matching([.overview, .applications, .developer, .cleanup])) { section in
                        Label { Text(section.title) } icon: { GUISectionIcon(section: section) }.tag(section)
                    }
                }
                Section("Manage") {
                    ForEach(matching([.updates, .recovery, .diagnostics, .history])) { section in
                        HStack {
                            Label { Text(section.title) } icon: { GUISectionIcon(section: section) }
                            Spacer()
                            if section == .diagnostics, let count = store.attentionCount, count > 0 {
                                Text(String(count)).font(.caption).foregroundStyle(.secondary)
                            }
                            if section == .recovery, let count = store.recoverySnapshot?.items.count, count > 0 {
                                Text(String(count)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)
            .disabled(!store.canNavigate)
            VStack(alignment: .leading, spacing: 10) {
                GUIVolumePicker(store: store).labelsHidden().controlSize(.small)
                    .disabled(store.isPerformingMutation)
                Button { store.showsSettings = true } label: { Label("Settings…", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
                    .disabled(!store.canOpenSettings)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220, idealWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }

    private func matching(_ sections: [GUISection]) -> [GUISection] {
        sections.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
}

struct GUIMainContentView: View {
    @ObservedObject var store: GUIStore
    @AppStorage("macbay.gui.appearance") private var appearance = "system"
    @AppStorage("macbay.gui.onboardingCompleted") private var setupCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch store.section {
                case .overview: GUIOverviewView(store: store)
                case .applications: GUIApplicationsView(store: store)
                case .developer: GUIDeveloperView(store: store)
                case .cleanup: GUICleanupView(store: store)
                case .updates: GUIUpdateCenterView(store: store)
                case .recovery: GUIRecoveryCenterView(store: store)
                case .diagnostics: GUIDiagnosticsView(store: store)
                case .history: GUIHistoryView(store: store)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if store.isRefreshing || store.isScanning || store.isPreparingPreview || store.isExecutingAction || store.isDemo {
                HStack(spacing: 8) {
                    if store.isRefreshing || store.isScanning || store.isPreparingPreview || store.isExecutingAction {
                        ProgressView().controlSize(.mini)
                        Text(statusSummary).lineLimit(1)
                    }
                    Spacer()
                    if store.isDemo { Text("Demo data") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(GUIWindowAppearance(appearance: appearance))
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .task {
            if !store.isDemo && !setupCompleted { store.requestSetup() }
            await store.start()
        }
        .task(id: store.section) {
            if store.section == .cleanup && !store.hasScannedCaches { await store.scanCaches() }
        }
        .sheet(item: $store.preview, onDismiss: { store.dismissPreview() }) { preview in
            GUIPreviewView(preview: preview) { store.dismissPreview() }
        }
        .sheet(isPresented: Binding(get: { store.showsActionSheet }, set: { if !$0 { store.dismissAction() } })) {
            GUIWorkflowSheet(store: store)
        }
        .sheet(isPresented: $store.showsSetup, onDismiss: { store.dismissSetup() }) {
            GUISetupView(store: store)
        }
        .sheet(isPresented: $store.showsReleaseCheck) {
            GUIReleaseCheckView(store: store)
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text("Unable to Prepare Preview"), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var statusSummary: String {
        if store.isExecutingAction { return store.actionProgress.message }
        if store.isRefreshing { return "Refreshing…" }
        if store.isScanning { return "Scanning applications…" }
        if store.statusError != nil { return "Storage unavailable" }
        if let drive = store.selectedVolume { return drive.name + " · " + GUIFormat.bytes(drive.availableBytes) + " available" }
        return store.statusReport == nil ? "Reading storage…" : "No external drive selected"
    }
}

struct GUISectionIcon: View {
    let section: GUISection
    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
    private var color: Color {
        switch section {
        case .overview, .history: return .gray
        case .applications, .developer, .updates: return .blue
        case .cleanup: return .purple
        case .recovery: return .orange
        case .diagnostics: return .green
        }
    }
}

enum GUIAssets {
    static let bundle: Bundle = {
        // SwiftPM 5.x and Swift Build 6.x generate different executable bundle searches.
        // Resolve the standard .app resource location explicitly before the development fallback.
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("MacBay_MacBayGUI.bundle")) {
            return bundle
        }
        return .module
    }()
    static let icon: NSImage = {
        if let url = bundle.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "MacBay")!
    }()
}

struct GUISettingsView: View {
    @ObservedObject var store: GUIStore
    var openMainWindow: () -> Void = {}
    @AppStorage("macbay.gui.appearance") private var appearance = "system"
    @AppStorage("macbay.gui.compactRows") private var compactRows = false
    @AppStorage("macbay.gui.showInspector") private var showInspector = true

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    Text("Follow System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Compact application rows", isOn: $compactRows)
                Toggle("Show app details panel", isOn: $showInspector)
            }
            Section {
                GUIMenuBarSettings()
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Closing the main window keeps MacBay in the menu bar. Left gauge: Mac. Right gauge: selected external drive.")
            }
            Section("Notifications") { GUINotificationSetting() }
            Section("MacBay") {
                Button("Run Setup Again…") { openMainWindow(); store.requestSetup() }.disabled(!store.canOpenSetup)
                Button("Check for Updates…") { openMainWindow(); store.requestReleaseCheck() }.disabled(!store.canCheckForAppUpdates)
                LabeledContent("Version", value: GUIAppInfo.version)
            }
        }
        .formStyle(.grouped)
        .background(GUIWindowAppearance(appearance: appearance))
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}

struct GUIPageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GUIPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox { content.padding(8).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct GUIBadge: View {
    let title: String
    var color: Color = .secondary
    var body: some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(color)
    }
}

struct GUIEmptyView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GUIVolumePicker: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        Picker("Destination", selection: $store.selectedVolumePath) {
            Text("Choose an external drive").tag(String?.none)
            ForEach(store.statusReport?.externalVolumes ?? []) { volume in
                Text(volume.name + " · " + GUIFormat.bytes(volume.availableBytes) + " free").tag(Optional(volume.path))
            }
        }.pickerStyle(.menu).frame(maxWidth: 380, alignment: .leading).disabled(store.isPerformingMutation)
    }
}
