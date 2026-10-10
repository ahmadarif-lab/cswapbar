import Foundation

/// Everything that shells out to the `codex` CLI.
///
/// The 5-hour window is a rolling one, anchored on the first request after the
/// previous reset, so starting it deliberately needs a real message to the
/// model. The only thing that can send one is the login the CLI itself holds
/// (CSwapBar never renews or reuses that login directly), so warm-up goes
/// through the same CLI the user already runs -- the way OpenCode Go's goes
/// through `opencode`.
enum CodexCLI {
    /// Where Codex is usually installed: the Homebrew cask and the npm global
    /// both land on one of these, and a GUI app launched from Finder inherits
    /// a bare PATH that has none of them.
    private static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
        ]
    }

    static func findBinary() -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in searchDirectories + pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The app's own environment with the usual CLI install dirs prepended, so
    /// `codex` -- and anything it shells out to -- resolves.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = searchDirectories + ["/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// One throwaway turn. `--ephemeral` keeps it from leaving a session
    /// behind in `~/.codex/sessions`, the read-only sandbox means the model
    /// can't touch anything even if it tried, and a low reasoning effort keeps
    /// it from spending more of the window than it has to. The model is left
    /// to the user's own config, since model names churn between releases.
    static let warmupArguments = [
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "-s", "read-only",
        "-c", "model_reasoning_effort=\"low\"",
        "Reply with the single word: ok.",
    ]
}
