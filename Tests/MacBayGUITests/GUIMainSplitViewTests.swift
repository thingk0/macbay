import AppKit
import SwiftUI
import XCTest
@testable import MacBayGUI

final class GUIMainSplitViewTests: XCTestCase {
    @MainActor
    func testNativeToggleAndModelVisibilityStayInSyncWithoutReplacingContent() async throws {
        let (controller, store, window) = try await makeWindow()
        defer { window.orderOut(nil); window.close() }
        let sidebar = try XCTUnwrap(controller.splitViewItems.first)
        let content = try XCTUnwrap(controller.splitViewItems.last?.viewController)
        let originalWidth = window.frame.width
        controller.toggleSidebar(nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(sidebar.isCollapsed)
        XCTAssertFalse(store.showsSidebar)
        XCTAssertEqual(window.frame.width, originalWidth, accuracy: 1)
        controller.toggleSidebar(nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(store.showsSidebar)
        XCTAssertTrue(controller.splitViewItems.last?.viewController === content)
        store.showsSidebar = false
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(sidebar.isCollapsed)
        store.showsSidebar = true
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(store.showsSidebar)
    }

    @MainActor
    func testRapidNativeTogglesDoNotReplayOldVisibilityChanges() async throws {
        let (controller, store, window) = try await makeWindow()
        defer { window.orderOut(nil); window.close() }
        controller.toggleSidebar(nil)
        controller.toggleSidebar(nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        let sidebar = try XCTUnwrap(controller.splitViewItems.first)
        let settledVisibility = !sidebar.isCollapsed
        // AppKit can coalesce repeated actions while its transition is running.
        XCTAssertEqual(store.showsSidebar, settledVisibility)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(!sidebar.isCollapsed, settledVisibility)
        XCTAssertEqual(store.showsSidebar, settledVisibility)
    }

    @MainActor
    private func makeWindow() async throws -> (GUIMainSplitViewController, GUIStore, NSWindow) {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacBaySplitTests-" + UUID().uuidString))
        defaults.register(defaults: ["macbay.gui.appearance": "system"])
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        let controller = GUIMainSplitViewController(store: store, defaults: defaults)
        controller.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1040, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.orderFrontRegardless()
        window.display()
        try await Task.sleep(nanoseconds: 100_000_000)
        return (controller, store, window)
    }
}
