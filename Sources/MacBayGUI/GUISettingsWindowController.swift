import AppKit
import Combine
import SwiftUI

/// Settings has its own reusable native window; setup and confirmation stay in the main window.
@MainActor
public final class GUISettingsWindowController: NSObject, NSWindowDelegate {
    private let store: GUIStore
    private let openMainWindow: () -> Void
    private var window: NSWindow?
    private var subscription: AnyCancellable?

    public init(store: GUIStore, openMainWindow: @escaping () -> Void) {
        self.store = store
        self.openMainWindow = openMainWindow
        super.init()
        subscription = store.$showsSettings.receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible { self.present() }
                else if self.window?.isVisible == true { self.window?.close() }
            }
    }

    public func show() {
        guard store.canOpenSettings else { return }
        if store.showsSettings { present() }
        else { store.showsSettings = true }
    }

    private func present() {
        guard store.canOpenSettings else {
            store.showsSettings = false
            return
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 590),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentMinSize = NSSize(width: 460, height: 460)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:
                GUISettingsView(store: store, openMainWindow: openMainWindow))
            window.setContentSize(NSSize(width: 520, height: 590))
            window.setFrameAutosaveName("MacBaySettingsWindow")
            window.center()
            window.delegate = self
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        store.showsSettings = false
        store.settingsDismissed()
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }
}
