import CryptoKit
import Foundation

/// `oauth.RefreshOutcome`. `error` is nil on success, else one of
/// `invalid_grant`, `invalid_client`, `no_refresh_token`, `transient`, or a
/// consume-gate kind (`consume-busy`, `stash-unreadable`, `store-unmirrored`).
struct RefreshOutcome {
    var credentials: String?
    var error: String?
    var tokenAccount: ResolvedIdentity? = nil
    var consumedFp: String? = nil
    var stashed = false
}

/// An OAuth identity as the profile or token endpoint reports it.
struct ResolvedIdentity: Equatable {
    var uuid: String
    var email: String?
    var organizationUuid: String?

    var json: JSONValue {
        .object(JSONObject([
            ("uuid", .string(uuid)),
            ("email", email.map { .string($0) } ?? .null),
            ("organizationUuid", organizationUuid.map { .string($0) } ?? .null),
        ]))
    }
}

/// `oauth.UsageOutcome`.
struct UsageOutcome {
    var usage: JSONValue?
    var error: String? = nil
    var retryAfter: Double? = nil
    var struckFp: String? = nil
}

/// A usage-endpoint failure, reduced to cswap's kind strings.
enum UsageFetchError: Error {
    case http(code: Int, retryAfter: Double?)
    case timeout
    case network
    case badResponse
    case other(String)

    var kind: String {
        switch self {
        case .http(let code, _): return "http-\(code)"
        case .timeout: return "timeout"
        case .network: return "network"
        case .badResponse: return "bad-response"
        case .other(let name): return name
        }
    }

    var retryAfter: Double? {
        if case .http(_, let ra) = self { return ra }
        return nil
    }
}

/// `oauth.py`: token refresh, identity lookup and the usage API.
struct OAuth {
    static let betaHeader = "oauth-2025-04-20"
    static let expiryBufferMs: Int64 = 5 * 60 * 1000
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Same UA class as cswap: the usage endpoint budgets per identity × UA,
    /// and this app shares cswap's budget and poll plans.
    static let userAgent = "claude-swap/1.0"

    /// Refresh failures that will not resolve by retrying this pass.
    static let deterministicRefreshErrors: Set<String> = [
        "store-unmirrored", "invalid_client", "consume-busy", "stash-unreadable",
    ]

    let env: EngineEnvironment
    let log: SwapLog

    // MARK: Credential parsing

    static func parseObject(_ text: String) -> JSONObject? {
        (try? JSONValue.parse(text))?.objectValue
    }

    static func extractAccessToken(_ credentials: String) -> String? {
        extractOAuthData(credentials)?["accessToken"]?.stringValue
    }

    static func extractOAuthData(_ credentials: String) -> JSONObject? {
        parseObject(credentials)?["claudeAiOauth"]?.objectValue
    }

    /// Refresh-token hash when there is one (stable across access-token
    /// rotation), full-content hash otherwise. nil only for empty input.
    static func credentialFingerprint(_ credentials: String?) -> String? {
        guard let credentials, !credentials.isEmpty else { return nil }
        if let token = extractOAuthData(credentials)?["refreshToken"]?.stringValue, !token.isEmpty {
            return "sha256:" + sha256Hex(token)
        }
        return "sha256-full:" + sha256Hex(credentials)
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func nowMs() -> Int64 { Int64((env.epoch * 1000).rounded(.towardZero)) }

    /// Expired or within the 5-minute buffer. Non-numbers are "not expired".
    func isTokenExpired(_ expiresAt: JSONValue?) -> Bool {
        guard let n = expiresAt?.numberValue, let exp = n.truncatedInt64 else { return false }
        return nowMs() + Self.expiryBufferMs >= exp
    }

    // MARK: Refresh

    func tryRefresh(_ credentials: String, timeout: TimeInterval = 10) -> RefreshOutcome {
        guard let parsed = try? JSONValue.parse(credentials) else { return RefreshOutcome(error: "transient") }
        guard var data = parsed.objectValue else { return RefreshOutcome(error: "transient") }
        guard var oauth = data["claudeAiOauth"]?.objectValue,
              let refreshToken = oauth["refreshToken"], refreshToken.isTruthy else {
            return RefreshOutcome(error: "no_refresh_token")
        }

        let body = JSONValue.object(JSONObject([
            ("grant_type", .string("refresh_token")),
            ("refresh_token", refreshToken),
            ("client_id", .string(Self.clientID)),
        ])).serialized()
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try env.http.send(req, timeout: timeout)
        } catch {
            log.debug("OAuth refresh failed: \(error)")
            return RefreshOutcome(error: "transient")
        }

        guard (200..<300).contains(response.status) else {
            let bodyText = String(decoding: response.body, as: UTF8.self)
            log.debug("OAuth refresh failed: HTTP \(response.status), body: \(bodyText.prefix(500))")
            if [400, 401, 403].contains(response.status),
               let err = (try? JSONValue.parse(response.body))?.objectValue?["error"]?.stringValue,
               err == "invalid_grant" || err == "invalid_client" {
                return RefreshOutcome(error: err)
            }
            return RefreshOutcome(error: "transient")
        }

        guard let resp = (try? JSONValue.parse(response.body))?.objectValue,
              let access = resp["access_token"],
              let expiresIn = resp["expires_in"]?.numberValue else {
            return RefreshOutcome(error: "transient")
        }
        let now = nowMs()
        oauth["accessToken"] = access
        if expiresIn.isInteger, let secs = Int64(expiresIn.literal) {
            oauth["expiresAt"] = .int64(now + secs * 1000)
        } else {
            oauth["expiresAt"] = .double(Double(now) + expiresIn.doubleValue * 1000)
        }
        if let rt = resp["refresh_token"], rt.isTruthy {
            oauth["refreshToken"] = rt
        }
        if let scope = resp["scope"], scope.isTruthy {
            guard let scopeText = scope.stringValue else { return RefreshOutcome(error: "transient") }
            oauth["scopes"] = .array(scopeText.split(whereSeparator: { $0.isWhitespace }).map { .string(String($0)) })
        }
        data["claudeAiOauth"] = .object(oauth)
        return RefreshOutcome(
            credentials: JSONValue.object(data).serialized(),
            error: nil,
            tokenAccount: Self.parseTokenAccount(resp)
        )
    }

    static func parseTokenAccount(_ resp: JSONObject) -> ResolvedIdentity? {
        guard let account = resp["account"]?.objectValue,
              let uuid = account["uuid"]?.stringValue,
              !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let org = resp["organization"]?.objectValue?["uuid"]?.stringValue
        return ResolvedIdentity(
            uuid: uuid.trimmingCharacters(in: .whitespacesAndNewlines),
            email: account["email_address"]?.stringValue,
            organizationUuid: org
        )
    }

    // MARK: Identity

    /// `GET /api/oauth/profile`: whose token is this. nil = unresolvable,
    /// never "wrong". Must not be called while any lock is held.
    func fetchProfile(_ accessToken: String) -> ResolvedIdentity? {
        var req = URLRequest(url: Self.profileURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let response = try? env.http.send(req, timeout: 5) else {
            log.debug("OAuth profile fetch failed")
            return nil
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 401 {
                log.warning(
                    "OAuth profile returned 401 while resolving credential ownership; proceeding without identity (pre-fix behavior)."
                )
            }
            return nil
        }
        guard let data = (try? JSONValue.parse(response.body))?.objectValue,
              let account = data["account"]?.objectValue,
              let uuid = account["uuid"]?.stringValue,
              !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ResolvedIdentity(
            uuid: uuid.trimmingCharacters(in: .whitespacesAndNewlines),
            email: account["email"]?.stringValue,
            organizationUuid: data["organization"]?.objectValue?["uuid"]?.stringValue
        )
    }

    // MARK: Usage

    func formatReset(_ resetsAt: String) -> (countdown: String, clock: String)? {
        TimeFormat.formatReset(resetsAt, now: env.now())
    }

    /// `fresh_reset_strings`: recomputed from `resets_at`; falls back to the
    /// fetch-time strings.
    func freshResetStrings(_ window: JSONObject) -> (countdown: String, clock: String)? {
        if let resetsAt = window["resets_at"], resetsAt.isTruthy,
           let s = resetsAt.stringValue, let cell = formatReset(s) {
            return cell
        }
        if let clock = window["clock"] {
            let countdown = window["countdown"]?.stringValue ?? "?"
            return (countdown, clock.stringValue ?? "")
        }
        return nil
    }

    func requestUsageData(_ accessToken: String) throws -> JSONValue {
        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do {
            response = try env.http.send(req, timeout: 5)
        } catch HTTPFailure.timeout {
            throw UsageFetchError.timeout
        } catch {
            throw UsageFetchError.network
        }
        guard (200..<300).contains(response.status) else {
            var retryAfter: Double?
            if let raw = response.header("Retry-After"), let v = Double(raw.trimmingCharacters(in: .whitespaces)) {
                retryAfter = max(0.0, v)
            }
            throw UsageFetchError.http(code: response.status, retryAfter: retryAfter)
        }
        do {
            return try JSONValue.parse(response.body)
        } catch {
            throw UsageFetchError.badResponse
        }
    }

    private func window(from raw: JSONObject) throws -> JSONObject {
        guard let utilization = raw["utilization"] else { throw UsageFetchError.other("KeyError") }
        var entry = JSONObject([("pct", utilization)])
        if let resetsAt = raw["resets_at"], resetsAt.isTruthy {
            guard let s = resetsAt.stringValue, let cell = formatReset(s) else {
                throw UsageFetchError.other("ValueError")
            }
            entry["resets_at"] = resetsAt
            entry["countdown"] = .string(cell.countdown)
            entry["clock"] = .string(cell.clock)
        }
        return entry
    }

    private static func pyFloat(_ v: JSONValue) -> Double? {
        switch v {
        case .number(let n): return n.doubleValue
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// `build_usage_result`: the internal (snake_case) usage dict that is
    /// also what `cache/usage.json` stores as `lastGood`.
    func buildUsageResult(_ data: JSONValue) throws -> JSONValue? {
        guard let d = data.objectValue else { throw UsageFetchError.other("AttributeError") }
        var result = JSONObject()

        if let h5 = d["five_hour"], h5.isTruthy {
            guard let obj = h5.objectValue else { throw UsageFetchError.other("TypeError") }
            result["five_hour"] = .object(try window(from: obj))
        }
        if let d7 = d["seven_day"], d7.isTruthy {
            guard let obj = d7.objectValue else { throw UsageFetchError.other("TypeError") }
            result["seven_day"] = .object(try window(from: obj))
        }

        if let eu = d["extra_usage"]?.objectValue, !eu.isEmpty, eu["is_enabled"]?.isTruthy == true {
            let used = eu["used_credits"], limit = eu["monthly_limit"], util = eu["utilization"]
            if let used, !used.isNull, let limit, !limit.isNull, let util, !util.isNull,
               let u = Self.pyFloat(used), let l = Self.pyFloat(limit), let p = Self.pyFloat(util) {
                var spend = JSONObject([
                    ("used", .double(u / 100)),
                    ("limit", .double(l / 100)),
                    ("pct", .double(p)),
                    ("currency", eu["currency"] ?? .string("USD")),
                ])
                var ok = true
                if let resetsAt = eu["resets_at"], resetsAt.isTruthy {
                    if let s = resetsAt.stringValue, let cell = formatReset(s) {
                        spend["resets_at"] = resetsAt
                        spend["countdown"] = .string(cell.countdown)
                        spend["clock"] = .string(cell.clock)
                    } else {
                        ok = false
                    }
                }
                if ok { result["spend"] = .object(spend) }
            }
        }

        if let limits = d["limits"]?.arrayValue {
            var scoped: [JSONValue] = []
            for lim in limits {
                guard let lim = lim.objectValue else { continue }
                let name = lim["scope"]?.objectValue?["model"]?.objectValue?["display_name"]
                guard let name, name.isTruthy, let pct = lim["percent"]?.numberValue else { continue }
                var entry = JSONObject([("name", name), ("pct", .double(pct.doubleValue))])
                if let resetsAt = lim["resets_at"], resetsAt.isTruthy {
                    guard let s = resetsAt.stringValue, let cell = formatReset(s) else {
                        throw UsageFetchError.other("ValueError")
                    }
                    entry["resets_at"] = resetsAt
                    entry["countdown"] = .string(cell.countdown)
                    entry["clock"] = .string(cell.clock)
                }
                scoped.append(.object(entry))
            }
            if !scoped.isEmpty { result["scoped"] = .array(scoped) }
        }

        return result.isEmpty ? nil : .object(result)
    }

    /// Every `(label, pct, resets_at)` window that gates an account.
    static func relevantWindows(_ usage: JSONValue?, models: [String] = []) -> [(label: String, pct: Double, resetsAt: String?)] {
        guard let u = usage?.objectValue else { return [] }
        var windows: [(String, Double, String?)] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            if let w = u[key]?.objectValue, let pct = w["pct"]?.numberValue {
                windows.append((label, pct.doubleValue, w["resets_at"]?.stringValue))
            }
        }
        if !models.isEmpty {
            let wanted = Set(models.map { $0.lowercased() })
            let matchAll = wanted.contains("all")
            for s in u["scoped"]?.arrayValue ?? [] {
                guard let s = s.objectValue, let pct = s["pct"]?.numberValue, let name = s["name"]?.stringValue else { continue }
                if matchAll || wanted.contains(name.lowercased()) {
                    windows.append((name, pct.doubleValue, s["resets_at"]?.stringValue))
                }
            }
        }
        return windows
    }

    /// Headroom of the binding window (`100 - max(pct)`), nil when unknown.
    static func accountHeadroom(_ usage: JSONValue?, models: [String] = []) -> Double? {
        let pcts = relevantWindows(usage, models: models).map(\.pct)
        guard let top = pcts.max() else { return nil }
        return 100.0 - top
    }

    func logUsageFailure(_ context: String, kind: String, retryAfter: Double?) {
        let place = context.isEmpty ? "" : " \(context)"
        var cause = retryAfter.map { "\(kind), retry-after \(String(format: "%.0f", $0))s" } ?? kind
        if kind == "http-429" { cause += " (usage-endpoint budget reached; backing off)" }
        log.warning("Usage fetch failed\(place): \(cause)")
    }

    private func fetchAndBuild(_ token: String) -> Result<JSONValue?, UsageFetchError> {
        do {
            let data = try requestUsageData(token)
            return .success(try buildUsageResult(data))
        } catch let e as UsageFetchError {
            return .failure(e)
        } catch {
            return .failure(.other("\(type(of: error))"))
        }
    }

    /// `try_fetch_usage_for_account`: refreshes an expired token for
    /// inactive accounts only — Claude Code owns the active one.
    func tryFetchUsageForAccount(
        accountNum: String,
        email: String,
        credentials: String,
        isActive: Bool,
        persist: ((String, String, String) throws -> Void)? = nil,
        refreshVia: ((String, String, String) -> RefreshOutcome)? = nil
    ) -> UsageOutcome {
        let context = "for account \(accountNum)"
        var oauth = Self.extractOAuthData(credentials)
        guard var accessToken = oauth?["accessToken"]?.stringValue, !accessToken.isEmpty else {
            return UsageOutcome(usage: nil, error: "no-access-token")
        }
        var working = credentials

        if !isActive, oauth?["refreshToken"]?.isTruthy == true, isTokenExpired(oauth?["expiresAt"]) {
            let refresh = refreshVia.map { $0(accountNum, email, working) } ?? tryRefresh(working)
            if let creds = refresh.credentials {
                working = creds
                if refreshVia == nil { persistRotated(persist, accountNum, email, working) }
                oauth = Self.extractOAuthData(working) ?? oauth
                if let t = oauth?["accessToken"]?.stringValue, !t.isEmpty { accessToken = t }
            } else if refresh.error == "invalid_grant" || refresh.error == "no_refresh_token" {
                return UsageOutcome(
                    usage: nil, error: refresh.error,
                    struckFp: refresh.consumedFp ?? Self.credentialFingerprint(working)
                )
            } else if let err = refresh.error, Self.deterministicRefreshErrors.contains(err) {
                return UsageOutcome(usage: nil, error: err)
            }
        }

        switch fetchAndBuild(accessToken) {
        case .success(let usage):
            return UsageOutcome(usage: usage)
        case .failure(let e):
            let kind = e.kind
            guard case .http(let code, _) = e, code == 401, !isActive, oauth != nil,
                  oauth?["refreshToken"]?.isTruthy == true else {
                logUsageFailure(context, kind: kind, retryAfter: e.retryAfter)
                return UsageOutcome(usage: nil, error: kind, retryAfter: e.retryAfter)
            }
            let refresh = refreshVia.map { $0(accountNum, email, working) } ?? tryRefresh(working)
            guard let creds = refresh.credentials else {
                logUsageFailure(context, kind: kind, retryAfter: nil)
                let dead = refresh.error == "invalid_grant" || refresh.error == "no_refresh_token"
                let distinct = dead || (refresh.error.map { Self.deterministicRefreshErrors.contains($0) } ?? false)
                return UsageOutcome(
                    usage: nil,
                    error: distinct ? refresh.error : "refresh-failed",
                    struckFp: dead ? (refresh.consumedFp ?? Self.credentialFingerprint(working)) : nil
                )
            }
            working = creds
            if refreshVia == nil { persistRotated(persist, accountNum, email, working) }
            guard let newToken = Self.extractOAuthData(working)?["accessToken"]?.stringValue, !newToken.isEmpty else {
                return UsageOutcome(usage: nil, error: "refresh-failed")
            }
            switch fetchAndBuild(newToken) {
            case .success(let usage):
                return UsageOutcome(usage: usage)
            case .failure(let retryError):
                logUsageFailure(context + " after refresh", kind: retryError.kind, retryAfter: retryError.retryAfter)
                return UsageOutcome(usage: nil, error: retryError.kind, retryAfter: retryError.retryAfter)
            }
        }
    }

    private func persistRotated(_ callback: ((String, String, String) throws -> Void)?, _ num: String, _ email: String, _ creds: String) {
        guard let callback else { return }
        do {
            try callback(num, email, creds)
        } catch {
            log.warning(
                "Refreshed OAuth token for account \(num) (\(email)) but failed to persist it: \(error). The refresh token on disk may now be stale; if the next refresh fails with invalid_grant, re-run `cswap --add-account` after logging in."
            )
        }
    }
}
