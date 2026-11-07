import AppKit
import MacBayGUI

@main
@MainActor
enum MacBayApp {
    static func main() {
        if CommandLine.arguments.contains("--version") { print(GUIAppInfo.version); return }
        let application = NSApplication.shared
        let delegate = MacBayAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class MacBayAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var mainWindowController: GUIMainWindowController?
    private var window: NSWindow? { mainWindowController?.window }
    private var store: GUIStore?
    private var menuBar: GUIMenuBarController?
    private var settingsWindow: GUISettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let service: any GUIServiceProtocol = demo ? DemoGUIService() : LiveGUIService()
        let store = GUIStore(service: service, isDemo: demo)
        self.store = store
        store.onActionCompleted = { result in
            if !demo { GUICompletionNotifications.shared.post(result) }
        }
        installMenus()
        settingsWindow = GUISettingsWindowController(store: store, openMainWindow: { [weak self] in self?.showWindow() })
        menuBar = GUIMenuBarController(store: store, openWindow: { [weak self] in self?.showWindow() },
                                      openSettings: { [weak self] in self?.showSettings() })
        let controller = GUIMainWindowController(store: store)
        mainWindowController = controller
        guard let window = controller.window else { return }
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #if DEBUG
        let startup = "MacBay startup: window=\(window.windowNumber) visible=\(window.isVisible) size=\(window.frame.size)\n"
        FileHandle.standardError.write(Data(startup.utf8))
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible != true { showWindow() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { menuBar?.isEnabled != true }
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.stop()
        settingsWindow?.stop()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isPerformingMutation == true { showOperationInProgress(); return .terminateCancel }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if store?.isPerformingMutation == true { showOperationInProgress(); return false }
        return true
    }
    private func showOperationInProgress() {
        let alert = NSAlert()
        alert.messageText = store?.isSavingSetup == true ? "Saving drive settings" : "An operation is in progress"
        alert.informativeText = store?.isSavingSetup == true
            ? "Keep MacBay open until your default drive has been saved."
            : "Keep MacBay open and the original drive connected until the operation finishes."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc private func showSettings() {
        guard let store, store.canOpenSettings else { return }
        settingsWindow?.show()
    }
    @objc private func showSetup() { showWindow(); store?.requestSetup() }
    @objc private func checkForUpdates() { showWindow(); store?.requestReleaseCheck() }
    @objc private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationVersion: GUIAppInfo.version])
    }
    @objc private func findApplication() {
        guard let store, store.canNavigate else { return }
        store.section = .applications
        store.searchFocusRequest += 1
    }
    @objc private func toggleSidebar() { mainWindowController?.splitController.toggleSidebar(nil) }
    @objc private func goBack() { mainWindowController?.goBack(nil) }
    @objc private func goForward() { mainWindowController?.goForward(nil) }
    @objc private func refresh() {
        guard let store, store.canRefreshView else { return }
        Task {
            await store.refresh()
            if store.section == .applications { await store.scanApplications() }
            if store.section == .cleanup { await store.scanCaches() }
        }
    }
    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MacBay")
        let about = appMenu.addItem(withTitle: "About MacBay", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacBay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let show = fileMenu.addItem(withTitle: "Show MacBay", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        let setup = fileMenu.addItem(withTitle: "Set Up MacBay…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = editMenu.addItem(withTitle: "Find Application…", action: #selector(findApplication), keyEquivalent: "f")
        find.target = self
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let back = viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        back.target = self
        let forward = viewMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        forward.target = self
        viewMenu.addItem(.separator())
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = self
        viewMenu.addItem(.separator())
        let refresh = viewMenu.addItem(withTitle: "Refresh", action: #selector(self.refresh), keyEquivalent: "r")
        refresh.target = self
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApplication.shared.mainMenu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let store else { return false }
        if menuItem.action == #selector(goBack) || menuItem.action == #selector(goForward) {
            let available = menuItem.action == #selector(goBack) ? store.navigationHistory.canGoBack : store.navigationHistory.canGoForward
            return available && store.canNavigate
        }
        switch menuItem.action {
        case #selector(showSetup): return store.canOpenSetup
        case #selector(checkForUpdates): return store.canCheckForAppUpdates
        case #selector(showSettings): return store.canOpenSettings
        case #selector(findApplication): return store.canNavigate
        case #selector(refresh): return store.canRefreshView
        default: return true
        }
    }
}
