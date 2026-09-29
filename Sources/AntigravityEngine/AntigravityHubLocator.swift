import Foundation
import ProviderKit

struct AntigravityHubEndpoint: Equatable {
    let port: Int
    let csrfToken: String
}

/// Finds a locally running `agy --hub` process -- the Antigravity CLI's own
/// background hub, spawned per active session (`agy --hub --hub-port=N
/// --csrf_token=... --add-dir=...`) -- by reading process argument lists via
/// `ps`, the same information any process can see about the user's own
/// processes on this machine.
///
/// Confirmed by hand against a real running hub: its Connect-RPC quota
/// endpoint returns live, complete usage data with no separate OAuth step,
/// while the cloud paths in `AntigravityOAuth`/`AntigravityQuotaClient`
/// return 403 SUBSCRIPTION_REQUIRED for accounts without a paid GCP Gemini
/// Code Assist license -- which is most Antigravity-only users. The hub is
/// only reachable while at least one CLI session is actually running, so
/// this is necessarily best-effort, not a persistent credential: when no
/// hub is found, `AntigravityEngine` falls back to the stored OAuth path.
enum AntigravityHubLocator {
    static func findRunningHub() -> AntigravityHubEndpoint? {
        guard let result = try? Subprocess.run("/bin/ps", ["-axo", "command="], timeout: 3), result.status == 0 else {
            return nil
        }
        return parse(result.stdout)
    }

    /// Pure parsing step, isolated from `ps` so it's unit-testable against
    /// captured process-list text.
    static func parse(_ psOutput: String) -> AntigravityHubEndpoint? {
        for line in psOutput.split(separator: "\n") {
            guard line.contains("agy"), line.contains("--hub") else { continue }
            guard let portText = value(in: line, forFlag: "--hub-port="), let port = Int(portText),
                  let token = value(in: line, forFlag: "--csrf_token="), !token.isEmpty else { continue }
            return AntigravityHubEndpoint(port: port, csrfToken: token)
        }
        return nil
    }

    private static func value(in line: Substring, forFlag flag: String) -> String? {
        guard let range = line.range(of: flag) else { return nil }
        let rest = line[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}
