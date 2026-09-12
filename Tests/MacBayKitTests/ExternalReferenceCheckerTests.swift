import Foundation
import XCTest
@testable import MacBayKit

final class ExternalReferenceCheckerTests: XCTestCase {
    private var tempDir: URL!
    private var appsDir: URL!
    private var otherAppsDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(FileManager.default.temporaryDirectory.path, &buffer)
        let resolvedTemp = String(cString: buffer)
        tempDir = URL(fileURLWithPath: resolvedTemp).appendingPathComponent("MacBayReferencesTests-\(UUID().uuidString)")
        appsDir = tempDir.appendingPathComponent("Applications")
        otherAppsDir = tempDir.appendingPathComponent("OtherApplications")

        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeChecker(
        fileManager: FileManager? = nil,
        currentDirectory: URL? = nil,
        limits: ConfigScanLimits = .standard
    ) -> ExternalReferenceChecker {
        ExternalReferenceChecker(
            fileManager: fileManager ?? .default,
            environment: [:],
            homeDirectory: tempDir,
            currentDirectory: currentDirectory,
            limits: limits
        )
    }

    @discardableResult
    private func check(
        paths: [String],
        apps: [URL]? = nil,
        fileManager: FileManager? = nil,
        currentDirectory: URL? = nil,
        limits: ConfigScanLimits = .standard,
        checker: ExternalReferenceChecker? = nil
    ) -> ExternalReferenceCheckResult {
        let used = checker ?? makeChecker(
            fileManager: fileManager,
            currentDirectory: currentDirectory,
            limits: limits
        )
        return used.check(
            paths: paths,
            applicationDirectories: apps ?? [appsDir]
        )
    }

    @discardableResult
    private func writeFile(_ relative: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func createApp(
        named name: String,
        in directory: URL? = nil,
        internalPaths: [String] = [],
        isSymlink: Bool = false
    ) throws {
        let appURL = (directory ?? appsDir).appendingPathComponent(name)
        if isSymlink {
            try FileManager.default.createSymbolicLink(at: appURL, withDestinationURL: appURL.appendingPathExtension("missing"))
            return
        }
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        for internalPath in internalPaths {
            let fileURL = appURL.appendingPathComponent(internalPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: fileURL)
        }
    }

    private func missingPath(_ app: String, _ internalPath: String) -> String {
        var path = "\(tempDir.path)/OldApps/\(app)"
        if !internalPath.isEmpty {
            path += "/" + internalPath
        }
        return path
    }

    private func findings(_ result: ExternalReferenceCheckResult, code: DoctorCode) -> [DoctorFinding] {
        result.findings.filter { $0.code == code }
    }

    private func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Only specified files are inspected

    func testNeighbourFilesAreNotInspected() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let checked = try writeFile("checked.json", contents: "{ \"bin\": \"\(missing)\" }")
        try writeFile("neighbour.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [checked.path])

        let candidates = findings(result, code: .externalReferenceMissing)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(standard(candidates.first?.paths[0] ?? ""), standard(checked.path))
    }

    func testDuplicatePathsAreCheckedOnce() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [file.path, file.path])

        XCTAssertEqual(findings(result, code: .externalReferenceMissing).count, 1)
        XCTAssertTrue(result.notes.contains { $0.contains("Only the files passed with --path were read") })
    }

    func testDirectoryPathIsRejected() throws {
        let directory = tempDir.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFile("settings/tool.json", contents: "{ \"bin\": \"/OldApps/Toolbox.app/bin/tool\" }")

        let result = check(paths: [directory.path])

        XCTAssertTrue(findings(result, code: .externalReferenceMissing).isEmpty)
        XCTAssertFalse(findings(result, code: .externalConfigUnreadable).isEmpty)
        XCTAssertTrue(result.notes.isEmpty || result.notes.allSatisfy { !$0.contains("Inspected") })
    }

    func testMissingFileIsReported() throws {
        let missing = tempDir.appendingPathComponent("does-not-exist.json").path

        let result = check(paths: [missing])

        let unreadable = try XCTUnwrap(findings(result, code: .externalConfigUnreadable).first)
        XCTAssertEqual(unreadable.status, .unableToVerify)
        XCTAssertEqual(unreadable.paths, [missing])
    }

    func testUnreadableFileIsReported() throws {
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"/OldApps/Toolbox.app/bin/tool\" }\n")
        let mock = MockFileManager(mountedPaths: [])
        mock.unreadableFilePaths.insert(file.path)
        mock.unreadableFilePaths.insert(file.standardizedFileURL.path)

        let result = check(paths: [file.path], fileManager: mock)

        let unreadable = try XCTUnwrap(findings(result, code: .externalConfigUnreadable).first)
        XCTAssertTrue(unreadable.detail.contains("could not be read"))
    }

    // MARK: - Detection

    func testMissingPathUsesConfirmingLanguage() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [file.path])

        let finding = try XCTUnwrap(findings(result, code: .externalReferenceMissing).first)
        XCTAssertEqual(finding.status, .needsAttention)
        XCTAssertEqual(finding.category, .externalReference)
        XCTAssertEqual(finding.name, "Toolbox.app")
        XCTAssertEqual(finding.paths.map(standard), [standard(file.path), standard(missing)])
        XCTAssertTrue(finding.detail.contains("does not confirm whether this setting is currently in use"))
        XCTAssertTrue(finding.recommendation.contains("Confirm whether this setting is currently in use"))
        XCTAssertFalse(finding.detail.lowercased().contains("moved"))
        XCTAssertFalse(finding.detail.lowercased().contains("deleted"))
    }

    func testExistingPathIsNotReported() throws {
        let app = appsDir.appendingPathComponent("Toolbox.app/bin/tool")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: app)
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(app.path)\" }")

        let result = check(paths: [file.path])

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(ReferenceReport(generatedAt: "x", findings: result.findings, notes: result.notes).exitCode, 0)
    }

    func testStaleCandidateReportsReplacement() throws {
        try createApp(named: "Toolbox.app", internalPaths: ["bin/tool"])
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [file.path])

        let candidate = try XCTUnwrap(findings(result, code: .externalReferenceStaleCandidate).first)
        XCTAssertEqual(candidate.status, .needsAttention)
        XCTAssertEqual(candidate.paths.count, 3)
        XCTAssertEqual(standard(candidate.paths[2]), standard(appsDir.appendingPathComponent("Toolbox.app/bin/tool").path))
        XCTAssertTrue(candidate.recommendation.contains("Confirm whether this setting is currently in use"))
    }

    func testWildcardAndTemplatePathsAreNotChecked() throws {
        let file = try writeFile("tool.json", contents: """
        { "glob": "/Applications/*.app", "template": "/Applications/<AppName>.app", "placeholder": "/Applications/AppName.app" }
        """)

        let result = check(paths: [file.path])

        XCTAssertTrue(findings(result, code: .externalReferenceStaleCandidate).isEmpty)
        XCTAssertTrue(findings(result, code: .externalReferenceMissing).isEmpty)
        XCTAssertTrue(findings(result, code: .externalReferenceUnverified).isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("wildcards") })
    }

    func testDisabledServersAreSkipped() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("config.toml", contents: """
        [mcp_servers.off]
        command = "\(missing)"
        enabled = false

        [mcp_servers.also_off]
        command = "\(missing)"
        disabled = true
        """)

        let result = check(paths: [file.path])

        XCTAssertTrue(result.findings.isEmpty)
    }

    func testParsersCoverJSONPlistTOMLAndText() throws {
        try createApp(named: "Toolbox.app", internalPaths: ["bin/tool"])
        let missing = missingPath("Toolbox.app", "bin/tool")
        let json = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")
        let toml = try writeFile("tool.toml", contents: "command = \"\(missing)\"\n")
        let ini = try writeFile("tool.ini", contents: "command=\(missing)\n")

        let plistURL = tempDir.appendingPathComponent("tool.plist")
        let plist: [String: Any] = ["Executable": missing]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

        let result = check(paths: [json.path, toml.path, ini.path, plistURL.path])

        let names = Set(findings(result, code: .externalReferenceStaleCandidate).map { URL(fileURLWithPath: $0.paths[0]).lastPathComponent })
        XCTAssertEqual(names, Set(["tool.json", "tool.toml", "tool.ini", "tool.plist"]))
    }

    func testUnsupportedTOMLConstructsArePartiallyChecked() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("config.toml", contents: """
        [mcp_servers.inline]
        env = { REPL = "\(missing)" }
        """)

        let result = check(paths: [file.path])

        let partial = try XCTUnwrap(findings(result, code: .externalConfigPartiallyChecked).first)
        XCTAssertEqual(partial.status, .unableToVerify)
        XCTAssertTrue(partial.recommendation.contains("Confirm whether this setting is currently in use"))
    }

    func testReadLimitsProduceIncompleteFinding() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let first = try writeFile("a.json", contents: "{ \"bin\": \"\(missing)\", \"pad\": \"\(String(repeating: "x", count: 80))\" }\n")
        let second = try writeFile("b.json", contents: "{ \"bin\": \"\(missing)\", \"pad\": \"\(String(repeating: "y", count: 80))\" }\n")

        let result = check(
            paths: [first.path, second.path],
            limits: ConfigScanLimits(
                maxDepth: 8,
                maxConfigFiles: 10_000,
                maxScanEntries: 100_000,
                maxFileBytes: 2 * 1024 * 1024,
                maxTotalReadBytes: 40
            )
        )

        XCTAssertFalse(findings(result, code: .externalReferenceScanIncomplete).isEmpty)
    }

    func testRelativeAndTildePaths() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        try writeFile("extra/settings.env", contents: "TOOL=\(missing)\n")

        let checker = ExternalReferenceChecker(
            fileManager: .default,
            environment: [:],
            homeDirectory: tempDir,
            currentDirectory: tempDir
        )
        let relative = check(paths: ["extra/settings.env"], checker: checker)
        XCTAssertEqual(findings(relative, code: .externalReferenceMissing).count, 1)

        let tilde = check(paths: ["~/extra/settings.env"], checker: checker)
        XCTAssertEqual(findings(tilde, code: .externalReferenceMissing).count, 1)
    }

    func testAmbiguousSameNamedAppsRemainUnverified() throws {
        try createApp(named: "Toolbox.app", internalPaths: ["bin/tool"])
        try FileManager.default.createDirectory(at: otherAppsDir, withIntermediateDirectories: true)
        try createApp(named: "Toolbox.app", in: otherAppsDir, internalPaths: ["bin/tool"])
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [file.path], apps: [appsDir, otherAppsDir])

        XCTAssertTrue(findings(result, code: .externalReferenceStaleCandidate).isEmpty)
        XCTAssertTrue(findings(result, code: .externalReferenceUnverified).first?.detail.contains("multiple applications") == true)
    }

    func testUnreadableApplicationDirectoryIsUnverified() throws {
        try createApp(named: "Toolbox.app", internalPaths: ["bin/tool"])
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let mock = MockFileManager(mountedPaths: [])
        mock.unreadableDirectoryPaths.insert(appsDir.path)

        let result = check(paths: [file.path], fileManager: mock)

        XCTAssertTrue(findings(result, code: .externalReferenceStaleCandidate).isEmpty)
        let unverified = try XCTUnwrap(findings(result, code: .externalReferenceUnverified).first)
        XCTAssertTrue(unverified.detail.contains("could not be read"))
    }

    func testCheckDoesNotModifyFiles() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")
        let before = try snapshot(of: tempDir)
        _ = check(paths: [file.path])
        XCTAssertEqual(try snapshot(of: tempDir), before)
        XCTAssertTrue(before.keys.contains(file.path))
    }

    func testNotesDescribeSpecifiedFilesOnly() throws {
        let missing = missingPath("Toolbox.app", "bin/tool")
        let file = try writeFile("tool.json", contents: "{ \"bin\": \"\(missing)\" }")

        let result = check(paths: [file.path])

        XCTAssertTrue(result.notes.contains { $0.contains("Inspected 1 specified configuration file") })
        XCTAssertTrue(result.notes.contains { $0.contains("does not confirm") })
    }

    private func snapshot(of root: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else {
            return entries
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if values.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                entries[item.path] = "link|\(destination)|\(modified)"
            } else {
                entries[item.path] = "file|\(values.fileSize ?? 0)|\(modified)"
            }
        }
        return entries
    }
}
