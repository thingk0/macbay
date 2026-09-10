import Foundation
import XCTest
@testable import MacBayKit

final class AppInspectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSafeAppBundleFixture() throws {
        let appURL = tempDir.appendingPathComponent("SafeApp.app")
        try createAppBundle(at: appURL, executableName: "SafeApp")

        let runner = TestEntitlementCommandRunner(xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict></dict></plist>")
        let inspector = AppInspector(commandRunner: runner)
        let assessment = inspector.assess(bundleURL: appURL)

        XCTAssertEqual(assessment.grade, .safe)
        XCTAssertTrue(assessment.reasons.isEmpty)
        XCTAssertTrue(assessment.evidence.isEmpty)
    }

    func testClaudeAsarMarkerFixture() throws {
        let appURL = tempDir.appendingPathComponent("ClaudeApp.app")
        try createAppBundle(at: appURL, executableName: "ClaudeApp")

        let resourcesURL = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let asarURL = resourcesURL.appendingPathComponent("app.asar")

        var asarData = Data("some preamble before marker ".utf8)
        asarData.append(Data("moveToApplicationsFolder".utf8))
        asarData.append(Data(" and some more payload".utf8))
        try asarData.write(to: asarURL)

        let runner = TestEntitlementCommandRunner(xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict></dict></plist>")
        let inspector = AppInspector(commandRunner: runner)
        let assessment = inspector.assess(bundleURL: appURL)

        XCTAssertEqual(assessment.grade, .popupRisk)
        XCTAssertTrue(assessment.reasons.contains { $0.contains("DMG relocation") })
        XCTAssertTrue(assessment.evidence.contains { $0.contains("moveToApplicationsFolder") })
    }

    func testOrbStackVirtualizationEntitlementFixture() throws {
        let appURL = tempDir.appendingPathComponent("OrbStackApp.app")
        try createAppBundle(at: appURL, executableName: "OrbStack")

        let entitlementsXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.virtualization</key>
            <true/>
        </dict>
        </plist>
        """

        let runner = TestEntitlementCommandRunner(xml: entitlementsXml)
        let inspector = AppInspector(commandRunner: runner)
        let assessment = inspector.assess(bundleURL: appURL)

        XCTAssertEqual(assessment.grade, .blocked)
        XCTAssertTrue(assessment.reasons.contains { $0.contains("virtualization") })
        XCTAssertTrue(assessment.evidence.contains { $0.contains("com.apple.security.virtualization=true") })
    }

    func testCorruptedBundleFixture() throws {
        let appURL = tempDir.appendingPathComponent("Corrupted.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        // Missing Info.plist

        let inspector = AppInspector()
        let assessment = inspector.assess(bundleURL: appURL)

        XCTAssertEqual(assessment.grade, .blocked)
        XCTAssertTrue(assessment.reasons.contains { $0.contains("missing or unreadable Info.plist") })
    }

    func testSystemExtensionsAreBlocked() throws {
        let appURL = tempDir.appendingPathComponent("SysExt.app")
        try createAppBundle(at: appURL, executableName: "SysExt")

        let extURL = appURL.appendingPathComponent("Contents/Library/SystemExtensions")
        try FileManager.default.createDirectory(at: extURL, withIntermediateDirectories: true)
        try Data().write(to: extURL.appendingPathComponent("dummy.systemextension"))

        let runner = TestEntitlementCommandRunner(xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict></dict></plist>")
        let inspector = AppInspector(commandRunner: runner)
        let assessment = inspector.assess(bundleURL: appURL)

        XCTAssertEqual(assessment.grade, .blocked)
        XCTAssertTrue(assessment.reasons.contains { $0.contains("system extensions") })
    }

    func testChunkedScanDetectsSignalAcrossChunkBoundary() throws {
        let fileURL = tempDir.appendingPathComponent("large.bin")
        let chunkSize = 64 * 1024
        var data = Data(repeating: 0x41, count: chunkSize - 10)
        data.append(Data("PFMoveToApplicationsFolder".utf8))
        data.append(Data(repeating: 0x42, count: 1000))
        try data.write(to: fileURL)

        let found = try AppInspector.searchSignals(
            in: fileURL,
            signals: ["PFMoveToApplicationsFolder"],
            chunkSize: chunkSize,
            overlapSize: 256
        )

        XCTAssertEqual(found, ["PFMoveToApplicationsFolder"])
    }

    private func createAppBundle(at url: URL, executableName: String) throws {
        let macosDir = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let execURL = macosDir.appendingPathComponent(executableName)
        try Data("binary payload".utf8).write(to: execURL)

        let plistDict: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.\(executableName)",
            "CFBundleName": executableName,
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistData.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}

final class TestEntitlementCommandRunner: CommandRunner, @unchecked Sendable {
    let xml: String
    var status: Int32 = 0

    init(xml: String, status: Int32 = 0) {
        self.xml = xml
        self.status = status
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        if executable.contains("codesign") {
            return CommandResult(status: status, standardOutput: xml, standardError: "")
        }
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}
