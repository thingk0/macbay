import Foundation
import XCTest
@testable import MacBayGUI

final class GUIReleaseCheckerTests: XCTestCase {
    private func checker(_ body: String, status: Int = 200, host: String = "api.github.com") -> GitHubGUIReleaseChecker {
        ReleaseProtocol.configure(body: body, status: status, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        return GitHubGUIReleaseChecker(session: URLSession(configuration: configuration))
    }
    func testNewStableReleaseUsesOnlyTheOfficialReleaseURLAndNoInventory() async throws {
        let result = try await checker(#"{"tag_name":"v1.10.1","draft":false,"prerelease":false}"#).check(installedVersion: "1.10.0")
        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.pageURL?.absoluteString, "https://github.com/thingk0/macbay/releases/tag/v1.10.1")
        let request = try XCTUnwrap(ReleaseProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/thingk0/macbay/releases/latest")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query)
    }
    func testVersionComparisonIsNumericAndHandlesInstalledDevelopmentVersions() async throws {
        let older = try await checker(#"{"tag_name":"v1.9.0","draft":false,"prerelease":false}"#).check(installedVersion: "1.10.0")
        XCTAssertEqual(older.status, .upToDate)
        let stable = try await checker(#"{"tag_name":"v1.10.0","draft":false,"prerelease":false}"#).check(installedVersion: "1.10.0-dev")
        XCTAssertEqual(stable.status, .updateAvailable)
    }
    func testNoReleaseIsDistinctFromFailedCheck() async throws {
        let missing = try await checker("{}", status: 404).check(installedVersion: "1.10.0")
        XCTAssertEqual(missing.status, .noPublishedRelease)
        do {
            _ = try await checker("{}", status: 403).check(installedVersion: "1.10.0")
            XCTFail("A failed check cannot appear up to date")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 403")) }
    }
    func testDraftPrereleaseMalformedAndRedirectedResponsesAreRejected() async {
        for body in [
            #"{"tag_name":"v2.0.0","draft":true,"prerelease":false}"#,
            #"{"tag_name":"v2.0.0-beta","draft":false,"prerelease":true}"#,
            #"{"tag_name":"https://example.com/payload","draft":false,"prerelease":false}"#,
            #"{"tag_name":"v9999999999999999999999999999.0.0","draft":false,"prerelease":false}"#
        ] {
            do { _ = try await checker(body).check(installedVersion: "1.10.0"); XCTFail("Expected rejection") }
            catch {}
        }
        do {
            _ = try await checker(#"{"tag_name":"v2.0.0","draft":false,"prerelease":false}"#, host: "example.com")
                .check(installedVersion: "1.10.0")
            XCTFail("Unexpected origin must be rejected")
        } catch {}
    }
}

private final class ReleaseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = ""
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var host = "api.github.com"
    nonisolated(unsafe) private static var request: URLRequest?
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
    static func configure(body: String, status: Int, host: String) {
        lock.lock(); defer { lock.unlock() }
        self.body = body; self.status = status; self.host = host; self.request = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        let body = Self.body, status = Self.status, host = Self.host
        Self.lock.unlock()
        let response = HTTPURLResponse(url: URL(string: "https://" + host + "/repos/thingk0/macbay/releases/latest")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
