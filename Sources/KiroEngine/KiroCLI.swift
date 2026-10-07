import Foundation
import ProviderKit

/// One `/usage` run's decoded result: the report text, plus the id of the
/// throwaway chat session the CLI had to open to produce it.
struct KiroUsageReport {
    let text: String
    let sessionID: String?
}

/// Everything that shells out to `kiro-cli`.
///
/// Kiro has no usage API to call and no credential file worth reading -- the
/// number only exists behind the CLI's own `/usage` slash command -- so this
/// runs `kiro-cli chat --no-interactive "/usage"`, the exact command a user
/// would type, and reads what it prints.
enum KiroCLI {
    /// The report is asked for as `stream-json` rather than as plain text:
    /// it's the same report, JSON-framed, which means the CLI's own session
    /// id comes back alongside it and `deleteSession` can clean up after.
    private static let usageArguments = ["chat", "--no-interactive", "--output-format", "stream-json", "/usage"]

    /// Finds the `kiro-cli` executable. A GUI app launched from Finder
    /// inherits a bare PATH, so the usual install dirs are checked by hand --
    /// including the app bundle its installer symlinks from `~/.local/bin`.
    static func findBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/kiro-cli",
            "\(home)/.kiro/bin/kiro-cli",
            "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "/usr/bin/kiro-cli",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("kiro-cli").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// The app's own environment with the usual CLI install dirs prepended,
    /// so `kiro-cli` -- and whatever it shells out to -- resolves.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "\(home)/.local/bin",
            "\(home)/.kiro/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// Runs the `/usage` command and returns its report. Blocking -- call off
    /// the main actor.
    static func usageReport(binary: String) throws -> KiroUsageReport {
        let result = try Subprocess.run(
            binary,
            usageArguments,
            environment: environment(),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: 60
        )

        let stream = KiroStreamReport(stdout: result.stdout)
        if let text = stream.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KiroUsageReport(text: text, sessionID: stream.sessionID)
        }
        // Nothing parseable came back. A clean exit is still worth reading as
        // plain text, in case a Kiro version prints the report without the
        // stream framing; a failed exit is a CLI failure and said so.
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KiroEngineError.process("`kiro-cli chat` exited \(result.status): \(String(detail.prefix(300)))")
        }
        return KiroUsageReport(text: result.stdout, sessionID: stream.sessionID)
    }

    /// Removes the throwaway session a `/usage` run left behind, so polling
    /// Kiro doesn't fill `~/.kiro/sessions` with one entry per refresh. Goes
    /// through the CLI's own `--delete-session` rather than unlinking files,
    /// so its session index stays consistent. Best effort: a failed cleanup
    /// is logged, never surfaced -- it says nothing about the usage number.
    static func deleteSession(_ sessionID: String, binary: String) {
        do {
            let result = try Subprocess.run(
                binary,
                ["chat", "--no-interactive", "--delete-session", sessionID],
                environment: environment(),
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: 30
            )
            if result.status != 0 {
                DiagnosticLog.log("kiro", "cleaning up session \(sessionID) exited \(result.status)")
            }
        } catch {
            DiagnosticLog.log("kiro", "cleaning up session \(sessionID) failed: \(DiagnosticLog.describe(error))")
        }
    }
}

/// One `--output-format stream-json` run, decoded from its JSON Lines stdout
/// (ACP events, one self-describing object per line).
///
/// The run's answer is read from `runFinished`'s `finalText`, which is the
/// whole report in one field; if that event is ever missing, the
/// `agent_message_chunk` pieces the CLI streamed on the way there are
/// stitched back together instead.
struct KiroStreamReport {
    let sessionID: String?
    let text: String?

    init(stdout: String) {
        var sessionID: String?
        var chunks: [String] = []
        var finalText: String?

        for line in stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  let event = decoded as? [String: Any],
                  let type = event["type"] as? String,
                  let payload = event["data"] as? [String: Any] else { continue }

            if let id = payload["sessionId"] as? String { sessionID = id }
            switch type {
            case "runFinished":
                finalText = payload["finalText"] as? String
            case "sessionUpdate":
                if let update = payload["update"] as? [String: Any],
                   update["sessionUpdate"] as? String == "agent_message_chunk",
                   let content = update["content"] as? [String: Any],
                   let text = content["text"] as? String {
                    chunks.append(text)
                }
            default:
                break
            }
        }

        self.sessionID = sessionID
        self.text = finalText ?? (chunks.isEmpty ? nil : chunks.joined())
    }
}
