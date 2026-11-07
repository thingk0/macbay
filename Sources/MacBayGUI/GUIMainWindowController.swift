import AppKit
import Combine

/// A Settings-style window: a full-height sidebar and page navigation in the toolbar.
@MainActor
public final class GUIMainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    public static let defaultContentSize = NSSize(width: 900, height: 700)
    public static let minimumContentSize = NSSize(width: 800, height: 580)
    public let splitController: GUIMainSplitViewController
    private let store: GUIStore
    private let titleField = NSTextField(labelWithString: "Storage")
    private var navigationControl: NSSegmentedControl?
    private var subscriptions = Set<AnyCancellable>()
    private static let navigationItem = NSToolbarItem.Identifier("MacBayPageNavigation")
    private static let titleItem = NSToolbarItem.Identifier("MacBayPageTitle")
    private static let refreshItem = NSToolbarItem.Identifier("MacBayRefresh")

    public init(store: GUIStore, defaults: UserDefaults = .standard, autosaveName: String? = "MacBaySettingsStyleWindow") {
        self.store = store
        splitController = GUIMainSplitViewController(store: store, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.backgroundColor = .underPageBackgroundColor
        let appearance = defaults.string(forKey: "macbay.gui.appearance")
        window.appearance = appearance == "light" ? NSAppearance(named: .aqua)
            : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: "MacBayMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(Self.defaultContentSize)
        window.center()
        if let autosaveName {
            window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
        }
        store.$section.removeDuplicates().sink { [weak self] section in
            let title = section == .overview ? "Storage" : section.title
            self?.window?.title = title
            self?.titleField.stringValue = title
            self?.titleField.sizeToFit()
        }.store(in: &subscriptions)
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.updateNavigation()
            self?.window?.toolbar?.validateVisibleItems()
        }.store(in: &subscriptions)
        updateNavigation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:defaults:autosaveName:)") }

    @objc public func goBack(_ sender: Any?) { store.goBack() }
    @objc public func goForward(_ sender: Any?) { store.goForward() }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { store.goBack() }
        else { store.goForward() }
    }

    @objc private func refresh(_ sender: Any?) {
        Task {
            await store.refresh()
            if store.section == .applications { await store.scanApplications() }
            if store.section == .cleanup { await store.scanCaches() }
        }
    }

    private func updateNavigation() {
        let enabled = !store.isExecutingAction && !store.isSavingSetup && !store.showsActionSheet
        navigationControl?.setEnabled(enabled && store.navigationHistory.canGoBack, forSegment: 0)
        navigationControl?.setEnabled(enabled && store.navigationHistory.canGoForward, forSegment: 1)
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .sidebarTrackingSeparator, Self.navigationItem, Self.titleItem,
         .flexibleSpace, .toggleSidebar, Self.refreshItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.navigationItem:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!
            ], trackingMode: .momentary, target: self, action: #selector(navigate))
            control.segmentStyle = .texturedRounded
            control.setToolTip("Back", forSegment: 0)
            control.setToolTip("Forward", forSegment: 1)
            control.setWidth(28, forSegment: 0)
            control.setWidth(28, forSegment: 1)
            control.setAccessibilityLabel("Page navigation")
            navigationControl = control
            updateNavigation()
            item.view = control
            item.label = "Back and Forward"
            item.visibilityPriority = .high
        case Self.titleItem:
            titleField.font = .systemFont(ofSize: 14, weight: .semibold)
            titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleField.sizeToFit()
            item.view = titleField
            item.label = "Page"
            item.isBordered = false
            item.visibilityPriority = .high
        case Self.refreshItem:
            item.label = "Refresh"
            item.toolTip = "Refresh disk status and the current view"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refresh)
            item.isBordered = true
            item.autovalidates = true
        default: return nil
        }
        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.itemIdentifier == Self.refreshItem else { return true }
        return !store.isRefreshing && !store.isScanning && !store.isScanningCaches && !store.isExecutingAction
    }
}
