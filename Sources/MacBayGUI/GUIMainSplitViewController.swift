import AppKit
import Combine
import SwiftUI

/// Own the sidebar at the window level so AppKit supplies its material, edges, and transition.
@MainActor
public final class GUIMainSplitViewController: NSSplitViewController {
    private let store: GUIStore
    private let sidebar: NSSplitViewItem
    private var visibilitySubscription: AnyCancellable?
    private var collapsedObservation: NSKeyValueObservation?

    public init(store: GUIStore, defaults: UserDefaults = .standard) {
        self.store = store
        let sidebarHost = NSHostingController(rootView: GUIMainSidebarView(store: store).defaultAppStorage(defaults))
        let contentHost = NSHostingController(rootView: GUIMainContentView(store: store).defaultAppStorage(defaults))
        // The native split controller owns geometry; SwiftUI fills the allocated panes.
        sidebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        super.init(nibName: nil, bundle: nil)
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 280
        sidebar.preferredThicknessFraction = 0.255
        sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = false
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebar.isCollapsed = !store.showsSidebar
        sidebar.allowsFullHeightLayout = true
        let content = NSSplitViewItem(viewController: contentHost)
        content.minimumThickness = 560
        #if compiler(>=6.2) && !MACBAY_LEGACY_APPEARANCE
        if #available(macOS 26.0, *) { content.automaticallyAdjustsSafeAreaInsets = true }
        #endif
        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        splitView.isVertical = true
        splitView.autosaveName = "MacBayNativeMainSplitView"

        collapsedObservation = sidebar.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read the current value so rapid native toggles can't replay a stale state.
                let visible = !self.sidebar.isCollapsed
                guard self.store.showsSidebar != visible else { return }
                self.store.showsSidebar = visible
            }
        }
        visibilitySubscription = store.$showsSidebar.dropFirst().removeDuplicates()
            .sink { [weak self] visible in
                guard let self, self.sidebar.isCollapsed == visible else { return }
                self.setSidebarVisible(visible)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:defaults:)") }

    public override func toggleSidebar(_ sender: Any?) {
        setSidebarVisible(sidebar.isCollapsed)
    }

    private func setSidebarVisible(_ visible: Bool) {
        guard sidebar.isCollapsed == visible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebar.isCollapsed = !visible
        } else {
            // Use AppKit's standard transition rather than changing SwiftUI visibility instantly.
            super.toggleSidebar(nil)
        }
    }
}
