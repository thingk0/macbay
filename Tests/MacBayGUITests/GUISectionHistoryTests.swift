import XCTest
@testable import MacBayGUI

final class GUISectionHistoryTests: XCTestCase {
    @MainActor
    func testSidebarAndPageLinksShareBackAndForwardHistory() {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        XCTAssertFalse(store.navigationHistory.canGoBack)
        XCTAssertFalse(store.navigationHistory.canGoForward)
        store.section = .applications
        store.section = .developer
        store.section = .developer
        store.goBack()
        XCTAssertEqual(store.section, .applications)
        store.goBack()
        XCTAssertEqual(store.section, .overview)
        XCTAssertFalse(store.navigationHistory.canGoBack)
        store.goBack()
        XCTAssertEqual(store.section, .overview)
        store.goForward()
        XCTAssertEqual(store.section, .applications)
        store.goForward()
        XCTAssertEqual(store.section, .developer)
        XCTAssertFalse(store.navigationHistory.canGoForward)
    }

    @MainActor
    func testNewSelectionAfterGoingBackDiscardsForwardBranch() {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        store.section = .applications
        store.section = .developer
        store.goBack()
        store.section = .cleanup
        XCTAssertFalse(store.navigationHistory.canGoForward)
        store.goForward()
        XCTAssertEqual(store.section, .cleanup)
        store.goBack()
        XCTAssertEqual(store.section, .applications)
    }

    @MainActor
    func testBackWaitsForPendingOperationPreviewToClose() async throws {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        store.section = .applications
        store.selectedApplicationID = "/Applications/Xcode.app"
        await store.previewApplication()
        XCTAssertNotNil(store.actionPreview)
        store.goBack()
        XCTAssertEqual(store.section, .applications)
        XCTAssertNotNil(store.actionPreview)
        store.dismissAction()
        store.goBack()
        XCTAssertEqual(store.section, .overview)
    }

    @MainActor
    func testNavigationDoesNotChangeDestinationOrSelectedApplication() async {
        let store = GUIStore(service: DemoGUIService(), isDemo: true, monitorVolumes: false)
        await store.start()
        store.section = .applications
        store.selectedApplicationID = "/Applications/Xcode.app"
        let destination = store.selectedVolumePath
        store.section = .history
        store.goBack()
        XCTAssertEqual(store.section, .applications)
        XCTAssertEqual(store.selectedApplicationID, "/Applications/Xcode.app")
        XCTAssertEqual(store.selectedVolumePath, destination)
    }
}
