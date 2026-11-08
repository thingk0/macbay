import Foundation
import MacBayKit
import SwiftUI

public enum GUIAppInfo { public static let version = MacBayVersion.current }

public struct GUIReleaseInfo: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case upToDate, updateAvailable, noPublishedRelease }
    public let status: Status
    public let installedVersion: String
    public let latestVersion: String?
    public let pageURL: URL?
    public init(status: Status, installedVersion: String, latestVersion: String? = nil, pageURL: URL? = nil) {
        self.status = status; self.installedVersion = installedVersion; self.latestVersion = latestVersion; self.pageURL = pageURL
    }
}

public protocol GUIReleaseChecking: Sendable {
    func check(installedVersion: String) async throws -> GUIReleaseInfo
}

public actor GitHubGUIReleaseChecker: GUIReleaseChecking {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: configuration)
    }
    public func check(installedVersion: String) async throws -> GUIReleaseInfo {
        let endpoint = URL(string: "https://api.github.com/repos/Mildbit-Studio/macbay/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBay/" + installedVersion, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "api.github.com" else {
            throw GUIError.unavailable("The update service returned an unexpected response. No software was downloaded.")
        }
        if http.statusCode == 404 { return GUIReleaseInfo(status: .noPublishedRelease, installedVersion: installedVersion) }
        guard http.statusCode == 200 else {
            throw GUIError.unavailable("GitHub could not check for updates (HTTP \(http.statusCode)). Try again later.")
        }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        guard data.count <= 1_000_000, let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let latest = ReleaseVersion(release.tag_name), !latest.prerelease,
              let installed = ReleaseVersion(installedVersion) else {
            throw GUIError.unavailable("A valid stable MacBay release could not be verified. No software was downloaded.")
        }
        let newer = installed.numbers.lexicographicallyPrecedes(latest.numbers)
            || (installed.numbers == latest.numbers && installed.prerelease)
        return GUIReleaseInfo(status: newer ? .updateAvailable : .upToDate, installedVersion: installedVersion,
            latestVersion: latest.normalized,
            pageURL: URL(string: "https://github.com/Mildbit-Studio/macbay/releases/tag/" + release.tag_name))
    }
}

private struct ReleaseVersion {
    let numbers: [UInt64]
    let prerelease: Bool
    let normalized: String
    init?(_ value: String) {
        let pattern = #"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let bare = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = bare.split(separator: "-", maxSplits: 1)
        let numeric = pieces[0].split(separator: ".").compactMap { UInt64($0) }
        guard numeric.count == 3 else { return nil }
        numbers = numeric; prerelease = pieces.count > 1; normalized = String(pieces[0])
    }
}

struct GUIReleaseCheckView: View {
    @ObservedObject var store: GUIStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GUIPageHeading(title: "MacBay Updates", subtitle: "Installed version " + GUIAppInfo.version)
            if store.isCheckingRelease {
                ProgressView("Checking the latest stable release…")
            } else if let info = store.releaseInfo {
                Label(info.status == .updateAvailable ? "MacBay \(info.latestVersion ?? "") is available"
                      : info.status == .noPublishedRelease ? "No stable release has been published yet" : "You’re up to date",
                      systemImage: info.status == .updateAvailable ? "arrow.down.circle" : "checkmark.circle")
                    .font(.headline).foregroundStyle(.blue)
                if let url = info.pageURL {
                    Link(info.status == .updateAvailable ? "View Release & Download" : "View Latest Release", destination: url)
                        .guiButton(prominent: true)
                }
            } else if let error = store.releaseError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Text("Checks run only when requested. MacBay contacts GitHub without sending your app inventory or paths. Updates are downloaded and installed by you.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check Again") { Task { await store.checkForAppUpdates() } }.guiButton().disabled(store.isCheckingRelease)
                Spacer()
                Button("Done") { store.showsReleaseCheck = false }.guiButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500, height: 300)
    }
}
