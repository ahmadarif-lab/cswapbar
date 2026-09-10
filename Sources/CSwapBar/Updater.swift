import AppKit
import Foundation

/// Finds newer GitHub releases and installs them the way the app is
/// distributed: `brew upgrade` of the ahmadarif-lab/tap/cswapbar cask.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        /// Tag without its leading "v", e.g. "1.3.0".
        let version: String
        let pageURL: URL
    }

    /// nil for a `swift run` dev build, which has no Info.plist; update
    /// checks are off there.
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    @Published private(set) var latest: Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    /// Non-nil while an update runs: the step it is on.
    @Published private(set) var progressText: String?
    @Published private(set) var errorMessage: String?

    private static let cask = "ahmadarif-lab/tap/cswapbar"
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ahmadarif-lab/cswapbar/releases/latest")!

    private let cli = CswapCLI.shared
    private var checkTask: Task<Void, Never>?

    var isUpdating: Bool { progressText != nil }

    var availableUpdate: Release? {
        guard let latest, let current = Self.currentVersion,
              Self.isVersion(latest.version, newerThan: current) else { return nil }
        return latest
    }

    /// Checks at launch, then every 6 hours; a failed check (say, no network
    /// yet right after login) retries after 15 minutes.
    init() {
        guard Self.currentVersion != nil else { return }
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let succeeded = await self?.check() else { return }
                try? await Task.sleep(for: succeeded ? .seconds(6 * 3600) : .seconds(15 * 60))
            }
        }
    }

    @discardableResult
    func check() async -> Bool {
        guard !isChecking, !isUpdating else { return false }
        isChecking = true
        defer { isChecking = false }
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latest = Release(
                version: release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName,
                pageURL: release.htmlURL
            )
            lastChecked = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't check for updates"
            return false
        }
    }

    /// Homebrew installs are upgraded in place and relaunched; any other
    /// install (a DMG copied by hand) gets the release page instead.
    func update() async {
        guard let release = availableUpdate, !isUpdating else { return }
        guard Self.installedViaHomebrew else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        errorMessage = nil
        defer { progressText = nil }
        do {
            // `brew upgrade` only refreshes the tap itself when its last
            // update is a day old, so it may not know this release yet.
            progressText = "Updating Homebrew…"
            try await cli.brew(["update", "--quiet"])
            progressText = "Installing v\(release.version)…"
            try await cli.brew(["upgrade", "--cask", Self.cask])
        } catch {
            errorMessage = Self.briefMessage(for: error)
            return
        }

        // brew never quits the app it runs inside of, so this process is
        // still the old version: confirm the new one is on disk, then swap.
        guard let installed = Self.installedVersion, let current = Self.currentVersion,
              Self.isVersion(installed, newerThan: current) else {
            errorMessage = "Homebrew didn't install a newer version"
            return
        }
        relaunch()
    }

    /// A second instance started while this one is still alive steps aside
    /// (see AppDelegate), so the reopen waits for this process to exit.
    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
        ]
        do {
            try reopen.run()
        } catch {
            errorMessage = "Updated -- quit and reopen CSwapBar to finish"
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Component-wise and numeric, so "1.10.0" is newer than "1.9.2".
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version now on disk at this bundle's path, which differs from
    /// `currentVersion` once an upgrade has replaced the bundle.
    private static var installedVersion: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }

    /// The cask's Caskroom entry, under either Homebrew prefix.
    private static var installedViaHomebrew: Bool {
        ["/opt/homebrew/Caskroom/cswapbar", "/usr/local/Caskroom/cswapbar"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// brew's own "Error: …" line rather than its whole transcript.
    private static func briefMessage(for error: Error) -> String {
        if case CswapError.nonZeroExit(_, _, let output) = error {
            let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let line = lines.last(where: { $0.hasPrefix("Error:") }) ?? lines.last(where: { !$0.isEmpty }) {
                return line
            }
        }
        return error.localizedDescription
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
