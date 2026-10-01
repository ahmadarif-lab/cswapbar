import Foundation
import ProviderKit

/// Everything that shells out to the `opencode` CLI.
///
/// OpenCode Go's 5-hour window is a rolling one, anchored on the first request
/// after the previous reset -- so starting it deliberately needs a real
/// message to the model. The only credential that can send one is whatever
/// the CLI itself is set up with (a console session can't call the model
/// endpoints, and an API key isn't always what's connected), so warm-up goes
/// through the same CLI the user already runs -- the way Antigravity's warm-up
/// goes through `agy`.
enum OpenCodeGoCLI {
    /// Models are addressed as `<provider>/<model>`.
    static let providerPrefix = "opencode-go/"

    /// Finds the `opencode` executable. A GUI app launched from Finder
    /// inherits a bare PATH, so the usual install dirs are checked by hand.
    static func findBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "/usr/bin/opencode",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("opencode").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// The app's own environment with the usual CLI install dirs prepended,
    /// so `opencode` -- and whatever it shells out to -- resolves.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "\(home)/.opencode/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// One cheap model from `opencode models` output (`<provider>/<model>` per
    /// line), picked at run time rather than hard-coded, since Go's model
    /// line-up churns between releases -- the same reason `ZAIEngine` asks the
    /// endpoint for its own model list.
    ///
    /// Free models are skipped deliberately: they're unlimited and don't draw
    /// on the plan's windows, so a warm-up on one wouldn't start anything --
    /// better to report that nothing could be warmed up than to "succeed" at
    /// nothing.
    static func warmupModel(fromListing listing: String) -> String? {
        let ids = listing
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(providerPrefix) }
            .map { String($0.dropFirst(providerPrefix.count)) }
            .filter { !$0.isEmpty }

        let paid = ids.filter { !$0.lowercased().contains("free") }
        let flash = paid.filter { $0.lowercased().contains("flash") && !$0.lowercased().contains("vision") }
        return flash.first { $0 == "deepseek-v4-flash" } ?? flash.first ?? paid.first
    }
}
