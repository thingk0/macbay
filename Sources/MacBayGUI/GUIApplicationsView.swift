import AppKit
import MacBayKit
import SwiftUI

struct GUIApplicationsView: View {
    @ObservedObject var store: GUIStore
    @AppStorage("macbay.gui.compactRows") private var compactRows = false
    @AppStorage("macbay.gui.showInspector") private var showInspector = true
    @State private var showsCompactInspector = false
    var body: some View {
        GeometryReader { geometry in
            content(inlineInspector: geometry.size.width >= 640)
        }
    }

    private func content(inlineInspector: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Store large apps externally. Launch them as usual.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Location", selection: $store.appLocation) {
                    ForEach(GUIAppLocation.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                Spacer()
                GUISearchField(text: $store.search, focusRequest: store.searchFocusRequest).frame(width: 200)
            }
            HSplitView {
                if !store.hasScanned {
                    GUIEmptyView(symbol: "magnifyingglass", title: "Scanning applications…",
                                 message: "The first scan checks app sizes and relocation compatibility.")
                } else if store.visibleApplications.isEmpty {
                    GUIEmptyView(symbol: "app.dashed", title: "No matching applications",
                                 message: store.scanReport?.warnings.first ?? "Try another location or search.")
                } else {
                    Table(store.visibleApplications, selection: $store.selectedApplicationID) {
                        TableColumn("Application") { app in
                            HStack(spacing: 9) {
                                GUIAppIcon(app: app, demo: store.isDemo).frame(width: compactRows ? 20 : 24, height: compactRows ? 20 : 24)
                                Text(app.displayName).font(.callout).lineLimit(1)
                            }.padding(.vertical, compactRows ? 1 : 3)
                                .contextMenu {
                                    Button("Show in Finder") { GUIFileActions.reveal(app.path) }.disabled(store.isDemo)
                                    Button("Copy App Path") { GUIFileActions.copyPath(app.path) }
                                    if let external = app.externalPath {
                                        Button("Copy External Path") { GUIFileActions.copyPath(external) }
                                    }
                                }
                        }.width(min: 140, ideal: 180)
                        TableColumn("Status") { app in GUIBadge(title: app.state.rawValue, color: app.state.color) }
                            .width(90)
                        TableColumn("Size") { app in
                            Text(GUIFormat.bytes(app.sizeBytes)).font(.caption).monospacedDigit()
                        }.width(75)
                    }.tableStyle(.inset(alternatesRowBackgrounds: true))
                }
                if showInspector, inlineInspector, let app = store.selectedApplication {
                    inspector(app).frame(minWidth: 190, idealWidth: 210, maxWidth: 240, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(store.selectedApplication.map { $0.displayName + " · " + GUIFormat.bytes($0.sizeBytes) } ?? "Select an application")
                            .font(.callout.weight(.medium))
                        if showInspector, !inlineInspector, let app = store.selectedApplication {
                            Button { showsCompactInspector.toggle() } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Show application details")
                            .accessibilityLabel("Show " + app.displayName + " details")
                            .popover(isPresented: $showsCompactInspector) {
                                inspector(app).frame(width: 280, height: 380)
                            }
                        }
                    }
                    if store.selectedApplication?.isRestore == true {
                        Text("Restore to the original application location").font(.caption).foregroundStyle(.secondary)
                    } else {
                        GUIVolumePicker(store: store)
                    }
                }
                Spacer()
                Button {
                    Task { await store.previewApplication() }
                } label: {
                    HStack(spacing: 7) {
                        if store.isPreparingPreview { ProgressView().controlSize(.mini) }
                        Text(store.selectedApplication?.isRestore == true ? "Preview Restore" : "Preview Move")
                        Image(systemName: "arrow.right")
                    }
                }
                .guiButton(prominent: true).controlSize(.regular).disabled(!store.canPreviewApplication)
                .accessibilityIdentifier("preview-application")
            }
            Text("Ready reflects relocation checks. App update compatibility needs separate verification. Apps smaller than \(GUIFormat.bytes(store.scanReport?.minimumApplicationSizeBytes ?? AppScanner.defaultMinimumApplicationSizeBytes)) are omitted.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    private func inspector(_ app: GUIApplication) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                GUIAppIcon(app: app, demo: store.isDemo).frame(width: 48, height: 48)
                Text(app.displayName).font(.system(size: 15, weight: .semibold))
                GUIBadge(title: app.state.rawValue, color: app.state.color)
                Divider()
                detail("App size", GUIFormat.bytes(app.sizeBytes))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original path").font(.caption).foregroundStyle(.secondary)
                    GUIPathActions(path: app.path, demo: store.isDemo)
                }
                if let target = app.externalPath { detail("External location", target) }
                if !app.reasons.isEmpty {
                    Divider()
                    ForEach(app.reasons, id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !app.canPreview {
                    Text("Review Diagnostics or use the operation-specific CLI workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Diagnostics") { store.section = .diagnostics }.guiButton().controlSize(.small)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GUIAppIcon: View {
    let app: GUIApplication
    let demo: Bool
    var body: some View {
        if demo {
            Image(systemName: app.name == "Xcode.app" ? "hammer.fill" : app.name == "Android Studio.app" ? "gearshape.fill" : "app.fill")
                .resizable().scaledToFit().padding(5).foregroundStyle(.blue)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().scaledToFit()
        }
    }
}

extension GUIApplication.State {
    var color: Color {
        switch self {
        case .ready: return .green
        case .review: return .orange
        case .blocked, .unavailable: return .red
        case .external: return .blue
        case .unmanaged, .unverified: return .secondary
        }
    }
}
