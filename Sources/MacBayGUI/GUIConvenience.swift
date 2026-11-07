import AppKit
import SwiftUI
import UserNotifications

enum GUIFileActions {
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct GUIPathActions: View {
    let path: String
    let demo: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { GUIFileActions.copyPath(path) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy path").accessibilityLabel("Copy path")
            Button { GUIFileActions.reveal(path) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder").disabled(demo)
        }
    }
}

@MainActor
public final class GUICompletionNotifications: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = GUICompletionNotifications()
    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == "com.thingk0.macbay"
    }
    public func requestPermission() async throws -> Bool {
        guard Self.isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    public func post(_ result: GUIActionResult) {
        guard Self.isAvailable, UserDefaults.standard.bool(forKey: "macbay.gui.notifyOnCompletion") else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = result.title
            content.body = "Open MacBay to review the result and refreshed storage status."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct GUINotificationSetting: View {
    @AppStorage("macbay.gui.notifyOnCompletion") private var enabled = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Notify me when an operation finishes", isOn: $enabled)
                .disabled(!GUICompletionNotifications.isAvailable)
                .onChange(of: enabled) { value in
                    guard value else { return }
                    Task {
                        do {
                            let permitted = try await GUICompletionNotifications.shared.requestPermission()
                            if !permitted {
                                enabled = false
                                message = "Allow MacBay notifications in System Settings to enable completion alerts."
                            } else { message = nil }
                        } catch { enabled = false; message = error.localizedDescription }
                    }
                }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !GUICompletionNotifications.isAvailable {
                Text("Completion alerts are available from the packaged MacBay app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
