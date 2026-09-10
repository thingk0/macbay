import Foundation
import XCTest
@testable import MacBayKit

final class ConfigStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBayConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeStore(environment: [String: String] = [:]) -> ConfigStore {
        ConfigStore(environment: environment, homeDirectory: tempDir)
    }

    private func sampleDefaultVolume() -> DefaultVolume {
        DefaultVolume(
            path: "/Volumes/ExternalSSD",
            name: "ExternalSSD",
            uuid: "E1B2C3D4-0000-1111-2222-333344445555",
            savedAt: "2026-09-10T12:00:00Z"
        )
    }

    func testDefaultConfigPathUsesHomeDirectory() {
        XCTAssertEqual(
            makeStore().configURL.path,
            tempDir.appendingPathComponent(".config/macbay/config.json").path
        )
    }

    func testXDGConfigHomeOverridesConfigPath() {
        let xdgHome = tempDir.appendingPathComponent("xdg")
        XCTAssertEqual(
            makeStore(environment: ["XDG_CONFIG_HOME": xdgHome.path]).configURL.path,
            xdgHome.appendingPathComponent("macbay/config.json").path
        )
    }

    func testRelativeXDGConfigHomeIsIgnored() {
        XCTAssertEqual(
            makeStore(environment: ["XDG_CONFIG_HOME": "relative/config"]).configURL.path,
            tempDir.appendingPathComponent(".config/macbay/config.json").path
        )
    }

    func testMissingFileLoadsEmptyConfig() throws {
        let config = try makeStore().load()
        XCTAssertEqual(config.version, MacBayConfig.currentVersion)
        XCTAssertNil(config.defaultVolume)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = makeStore()
        let entry = sampleDefaultVolume()
        try store.save(MacBayConfig(defaultVolume: entry))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configURL.path))
        XCTAssertEqual(try store.load().defaultVolume, entry)
    }

    func testSaveUsesXDGDirectory() throws {
        let xdgHome = tempDir.appendingPathComponent("xdg")
        let store = makeStore(environment: ["XDG_CONFIG_HOME": xdgHome.path])
        try store.save(MacBayConfig(defaultVolume: sampleDefaultVolume()))

        let expected = xdgHome.appendingPathComponent("macbay/config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try store.load().defaultVolume, sampleDefaultVolume())
    }

    func testCorruptedConfigThrowsConfigFailed() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: store.configURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case let MacBayError.configFailed(path, details) = error else {
                return XCTFail("Expected configFailed, got \(error)")
            }
            XCTAssertEqual(path, store.configURL.path)
            XCTAssertFalse(details.isEmpty)
        }
    }

    func testUnsupportedVersionThrowsConfigFailed() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        try encoder.encode(MacBayConfig(version: 99, defaultVolume: sampleDefaultVolume()))
            .write(to: store.configURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case let MacBayError.configFailed(_, details) = error else {
                return XCTFail("Expected configFailed, got \(error)")
            }
            XCTAssertTrue(details.contains("99"))
        }
    }

    func testResetRemovesFileAndReturnsDefault() throws {
        let store = makeStore()
        let entry = sampleDefaultVolume()
        try store.save(MacBayConfig(defaultVolume: entry))

        XCTAssertEqual(try store.reset(), entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configURL.path))
        XCTAssertNil(try store.load().defaultVolume)
    }

    func testResetWithoutFileReturnsNil() throws {
        XCTAssertNil(try makeStore().reset())
    }

    func testResetAfterCorruptedConfigReturnsNilDefault() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("INVALID_JSON{[[[".utf8).write(to: store.configURL)

        XCTAssertNil(try store.reset())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configURL.path))
    }

    func testConfigFailedErrorMetadata() {
        let error = MacBayError.configFailed(path: "/tmp/config.json", details: "broken")
        XCTAssertEqual(error.errorCode, "configuration_error")
        XCTAssertEqual(error.errorDetails, "broken")
        XCTAssertEqual(error.errorDescription, "Configuration error at /tmp/config.json: broken. Run 'mb init --reset' to remove the saved configuration.")
        XCTAssertEqual(
            MacBayErrorPayload(error: error).error.message,
            "Configuration error at /tmp/config.json: broken. Run 'mb init --reset' to remove the saved configuration."
        )
    }
}
