import Foundation
import XCTest
import MacBayKit
@testable import MacBayTUI

final class TUIExplorerTests: XCTestCase {
    private func wait(_ app: TUIApp, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(condition())
    }

    private func explorerReport(entries: [ExplorerEntry], root: String = "/Users/me/Library/Application Support") -> ExplorerScanReport {
        ExplorerScanReport(
            rootPath: root,
            generatedAt: macBayTimestamp(),
            previousGeneratedAt: "2026-01-01T00:00:00Z",
            entries: entries,
            totalLogicalBytes: entries.map(\.logicalBytes).reduce(0, +),
            totalAllocatedBytes: entries.map(\.allocatedBytes).reduce(0, +),
            deltas: entries.map {
                ExplorerDelta(path: $0.path, name: $0.name, previousAllocatedBytes: $0.allocatedBytes, currentAllocatedBytes: $0.allocatedBytes, deltaAllocatedBytes: 0, status: .unchanged)
            }
        )
    }

    private func directoryEntry(name: String, size: UInt64) -> ExplorerEntry {
        ExplorerEntry(
            name: name,
            path: "/Users/me/Library/Application Support/\(name)",
            kind: .directory,
            logicalBytes: size,
            allocatedBytes: size,
            action: .directoryMove
        )
    }

    func testExplorerMenuOpensAndLoads() {
        let fake = FakeTUIService()
        fake.exploreReportToReturn = explorerReport(entries: [directoryEntry(name: "Steam", size: 32_000_000_000)])
        let app = TUIApp(service: fake)
        app.loadInitialData()
        wait(app) { !app.state.isLoading }
        app.handleKey(.down)
        app.handleKey(.enter)
        XCTAssertEqual(app.state.currentScreen, .explorer)
        wait(app) { app.state.explorerLoaded }
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Steam"])
        XCTAssertTrue(app.renderString().contains("Explore Disk Usage"))
    }

    func testExplorerMoveFlowReachesMovePreview() {
        let fake = FakeTUIService()
        fake.exploreReportToReturn = explorerReport(entries: [directoryEntry(name: "Steam", size: 32_000_000_000)])
        let app = TUIApp(service: fake)
        app.handleKey(.down)
        app.handleKey(.enter)
        wait(app) { app.state.explorerLoaded }
        app.handleKey(.char("m"))
        wait(app) { !app.state.isLoading }
        guard case let .dryRunPreview(plan) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(plan.operation, "move")
        XCTAssertTrue(plan.sourcePath.hasSuffix("Steam"))
        XCTAssertTrue(plan.messages.contains("Original path stays as a symlink; disconnecting the external volume makes this data unavailable"))
    }

    func testExplorerBlockedEntryShowsGuidance() {
        let fake = FakeTUIService()
        let blocked = ExplorerEntry(
            name: "Mail",
            path: "/Users/me/Library/Mail",
            kind: .directory,
            logicalBytes: 100,
            allocatedBytes: 100,
            action: .blocked(reason: "Refusing to externalize a protected location: /Users/me/Library/Mail")
        )
        fake.exploreReportToReturn = explorerReport(entries: [blocked])
        let app = TUIApp(service: fake)
        app.handleKey(.down)
        app.handleKey(.enter)
        wait(app) { app.state.explorerLoaded }
        app.handleKey(.char("m"))
        guard case .infoModal(let title, _, _) = app.state.currentScreen else {
            return XCTFail("Expected infoModal, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(title, "Protected Location")
    }

    func testExplorerFileEntryMovesInsteadOfUnsupported() {
        let fake = FakeTUIService()
        let file = ExplorerEntry(
            name: "big.iso",
            path: "/Users/me/Downloads/big.iso",
            kind: .file,
            logicalBytes: 100,
            allocatedBytes: 100,
            action: .fileMove
        )
        fake.exploreReportToReturn = explorerReport(entries: [file])
        let app = TUIApp(service: fake)
        app.handleKey(.down)
        app.handleKey(.enter)
        wait(app) { app.state.explorerLoaded }
        app.handleKey(.char("m"))
        wait(app) { !app.state.isLoading }
        guard case let .dryRunPreview(plan) = app.state.currentScreen else {
            return XCTFail("Expected dryRunPreview, got \(app.state.currentScreen)")
        }
        XCTAssertEqual(plan.operation, "move")
        XCTAssertTrue(plan.sourcePath.hasSuffix("big.iso"))
    }

    func testExplorerSearchSortRescan() {
        let fake = FakeTUIService()
        fake.exploreReportToReturn = explorerReport(entries: [
            directoryEntry(name: "Zulu", size: 30),
            directoryEntry(name: "Alpha", size: 10)
        ])
        let app = TUIApp(service: fake)
        app.handleKey(.down)
        app.handleKey(.enter)
        wait(app) { app.state.explorerLoaded }
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Zulu", "Alpha"])
        app.handleKey(.char("s"))
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Alpha", "Zulu"])
        app.handleKey(.char("s"))
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Zulu", "Alpha"])
        app.handleKey(.char("/"))
        app.handleKey(.char("z"))
        app.handleKey(.enter)
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Zulu"])
        app.handleKey(.char("c"))
        XCTAssertEqual(app.state.explorerEntries.count, 2)
        let calls = fake.exploreCalls.count
        app.handleKey(.char("r"))
        wait(app) { fake.exploreCalls.count > calls }
    }

    func testExplorerAutoRefreshAppliesChangedEntries() {
        let fake = FakeTUIService()
        fake.exploreReportToReturn = explorerReport(entries: [directoryEntry(name: "Steam", size: 10)])
        let app = TUIApp(service: fake)
        app.handleKey(.down)
        app.handleKey(.enter)
        wait(app) { app.state.explorerLoaded }
        let refreshed = explorerReport(entries: [directoryEntry(name: "Steam", size: 99)])
        fake.exploreReportToReturn = refreshed
        app.applyExplorerChangeEvent(changedPaths: ["/Users/me/Library/Application Support/Steam"])
        wait(app) { app.state.cachedExplorer?.totalAllocatedBytes == 99 }
        XCTAssertEqual(app.state.explorerEntries.map(\.name), ["Steam"])
    }
}
