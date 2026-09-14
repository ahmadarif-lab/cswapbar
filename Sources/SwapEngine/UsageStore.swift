import Foundation

/// `usage_store.FetchRecord`: exactly one of success (`error` and
/// `sentinel` nil), failure (`error`) or sentinel (never persisted).
struct FetchRecord {
    var usage: JSONValue? = nil
    var error: String? = nil
    var retryAfter: Double? = nil
    var sentinel: String? = nil
    var struckFp: String? = nil
}

/// `usage_store.UsageEntry`: one account's usage state at collect time.
struct UsageEntry {
    var sentinel: String? = nil
    var lastGood: JSONValue? = nil
    var fetchedAt: Double? = nil
    var ageS: Double? = nil
    var lastAttemptAt: Double? = nil
    var consecutiveFailures = 0
    var lastError: String? = nil
    var backoffUntil: Double? = nil
    var nextPollAt: Double? = nil
    var pollIntervalS: Double? = nil
    var last429At: Double? = nil
    var authDeadStrikes = 0
    var struckFingerprint: String? = nil
    var trustExtended = false
    var claimUntil: Double? = nil

    func recent429(_ now: Double) -> Bool {
        guard let last429At else { return false }
        var anchor = last429At
        if lastError == "http-429", let backoffUntil, backoffUntil > anchor { anchor = backoffUntil }
        return now < anchor + PollPolicy.recent429Window
    }

    func tokenDead(threshold: Int = UsageStore.authDeadStrikes, storedFp: String? = nil) -> Bool {
        if authDeadStrikes < threshold { return false }
        if let storedFp, let struckFingerprint, storedFp != struckFingerprint { return false }
        return true
    }

    /// `decision_value`: the value scripts (and this app) act on.
    enum Decision {
        case usage(JSONValue)
        case sentinel(String)
        case unknown
    }

    func decisionValue() -> Decision {
        if let sentinel { return .sentinel(sentinel) }
        if let lastGood, !lastGood.isNull, let ageS, ageS <= UsageStore.staleOK || trustExtended {
            return .usage(lastGood)
        }
        return .unknown
    }
}

/// `usage_store.UsageStore`: `cache/usage.json` (schema 2), shared with every
/// cswap surface. Writes are read-modify-write under `cache/.usage.lock`,
/// never across network I/O.
struct UsageStore {
    static let schemaVersion = 2
    static let staleOK: Double = 300
    static let claimTTL: Double = 90
    static let legacyClaimTTL: Double = 10
    static let trustMaxAge: Double = 3600
    static let rateLimitTrustMaxAge: Double = 7200
    static let backoffBase: Double = 30
    static let backoffCap: Double = 600
    static let backoffMaxShift = 32
    static let retryAfterMargin: Double = 900
    static let retryAfterFloorCap: Double = 4500
    static let authDeadStrikes = 1
    static let permanentAuthErrors: Set<String> = ["invalid_grant", "no_refresh_token"]

    typealias Identity = (email: String, org: String)

    let path: URL
    let lockPath: URL
    let clock: () -> Double

    init(cacheDir: URL, clock: @escaping () -> Double) {
        path = cacheDir.appendingPathComponent("usage.json")
        lockPath = cacheDir.appendingPathComponent(".usage.lock")
        self.clock = clock
    }

    // MARK: Raw I/O

    private func readRows() -> JSONObject {
        guard let data = try? Data(contentsOf: path),
              let raw = (try? JSONValue.parse(data))?.objectValue,
              let v = raw["schemaVersion"]?.numberValue, v.isInteger, v.literal == String(Self.schemaVersion),
              let rows = raw["accounts"]?.objectValue else { return JSONObject() }
        return rows
    }

    private func writeRows(_ rows: JSONObject) throws {
        try AtomicJSON.write(
            .object(JSONObject([("schemaVersion", .int(Self.schemaVersion)), ("accounts", .object(rows))])),
            to: path
        )
    }

    private static func matches(_ row: JSONValue?, _ identity: Identity) -> Bool {
        guard let row = row?.objectValue else { return false }
        return row["email"] == .string(identity.email)
            && (row["organizationUuid"] ?? .string("")) == .string(identity.org)
    }

    private static func freshRow(_ identity: Identity) -> JSONObject {
        JSONObject([("email", .string(identity.email)), ("organizationUuid", .string(identity.org))])
    }

    static func num(_ v: JSONValue?) -> Double? { v?.numberValue?.doubleValue }

    private static func pyInt(_ v: JSONValue?) -> Int {
        guard let v, v.isTruthy, let n = v.numberValue?.truncatedInt64 else { return 0 }
        return Int(n)
    }

    static func liveClaim(claimUntil: Double?, lastAttemptAt: Double?, now: Double) -> Bool {
        if let claimUntil { return now < claimUntil }
        if let lastAttemptAt { return (now - lastAttemptAt) < legacyClaimTTL }
        return false
    }

    // MARK: Read model

    func entries(_ identities: [String: Identity], models: [String] = []) -> [String: UsageEntry] {
        let now = clock()
        let rows = readRows()
        var out: [String: UsageEntry] = [:]
        for (num, identity) in identities {
            guard Self.matches(rows[num], identity), let row = rows[num]?.objectValue else {
                out[num] = UsageEntry()
                continue
            }
            let fetchedAt = Self.num(row["fetchedAt"])
            let lastGood = row["lastGood"].flatMap { $0.objectValue != nil ? $0 : nil }
            let age = fetchedAt.map { now - $0 }
            let failures = Self.pyInt(row["consecutiveFailures"])
            let nextPollAt = Self.num(row["nextPollAt"])
            let lastAttemptAt = Self.num(row["lastAttemptAt"])
            let claimUntil = Self.num(row["claimUntil"])
            let lastError = row["lastError"]?.stringValue
            let withinCeiling: Bool
            if lastError == "http-429" {
                withinCeiling = Self.rateLimitedTrustOK(lastGood, age: age, now: now, models: models)
            } else {
                withinCeiling = age.map { $0 <= Self.trustMaxAge } ?? false
            }
            let live = Self.liveClaim(claimUntil: claimUntil, lastAttemptAt: lastAttemptAt, now: now)
            let trustExtended = withinCeiling && (failures > 0 || (nextPollAt.map { now < $0 } ?? false) || live)
            out[num] = UsageEntry(
                lastGood: lastGood,
                fetchedAt: fetchedAt,
                ageS: age,
                lastAttemptAt: lastAttemptAt,
                consecutiveFailures: failures,
                lastError: lastError,
                backoffUntil: Self.num(row["backoffUntil"]),
                nextPollAt: nextPollAt,
                pollIntervalS: Self.num(row["pollIntervalS"]),
                last429At: Self.num(row["last429At"]),
                authDeadStrikes: Self.pyInt(row["authDeadStrikes"]),
                struckFingerprint: row["struckFingerprint"]?.stringValue,
                trustExtended: trustExtended,
                claimUntil: claimUntil
            )
        }
        return out
    }

    private static func earliestReset(_ lastGood: JSONValue?, models: [String]) -> Double? {
        OAuth.relevantWindows(lastGood, models: models).compactMap { PollPolicy.parseResetTs($0.resetsAt) }.min()
    }

    static func rateLimitedTrustOK(_ lastGood: JSONValue?, age: Double?, now: Double, models: [String]) -> Bool {
        guard let age else { return false }
        let ceiling = now + (rateLimitTrustMaxAge - age)
        if let soonest = earliestReset(lastGood, models: models) {
            return now < min(soonest, ceiling)
        }
        return now < ceiling
    }

    static func failureBackoff(_ failures: Int, retryAfter: Double?, rateLimited: Bool) -> Double {
        let shift = min(max(0, failures - 1), backoffMaxShift)
        let computed = min(backoffBase * pow(2.0, Double(shift)), backoffCap)
        guard let retryAfter else { return computed }
        if retryAfter == 0 {
            if !rateLimited { return computed }
            return min(max(computed, PollPolicy.edgeBackoff), backoffCap)
        }
        var asked = retryAfter
        if retryAfter > backoffCap && rateLimited {
            asked = retryAfter + retryAfterMargin
        }
        asked = min(asked, rateLimited ? retryAfterFloorCap : trustMaxAge)
        return max(asked, computed)
    }

    static func planOversleepsInterval(nextPollAt: Double?, pollInterval: Double?, now: Double) -> Bool {
        guard let nextPollAt else { return false }
        let interval = max((pollInterval.flatMap { $0 == 0 ? nil : $0 }) ?? PollPolicy.exhaustedInterval, PollPolicy.exhaustedInterval)
        let latest = now + interval * (1.0 + PollPolicy.jitterFrac) + PollPolicy.resetSlack
        return nextPollAt > latest
    }

    private static func rowEligible(_ row: JSONObject, now: Double, respectPlans: Bool, repairOverslept: Bool) -> Bool {
        if pyInt(row["authDeadStrikes"]) >= authDeadStrikes { return false }
        if let b = num(row["backoffUntil"]), now < b { return false }
        if liveClaim(claimUntil: num(row["claimUntil"]), lastAttemptAt: num(row["lastAttemptAt"]), now: now) { return false }
        let fetchedAt = num(row["fetchedAt"])
        let stale = fetchedAt == nil || (now - fetchedAt!) > PollPolicy.serveTTL
        let nextPollAt = num(row["nextPollAt"])
        let pollDue = nextPollAt.map { now >= $0 } ?? false
        let overslept = repairOverslept
            && planOversleepsInterval(nextPollAt: nextPollAt, pollInterval: num(row["pollIntervalS"]), now: now)
        if respectPlans { return stale && (pollDue || nextPollAt == nil || overslept) }
        if repairOverslept { return pollDue || (stale && (nextPollAt == nil || overslept)) }
        return pollDue || stale
    }

    // MARK: Writes

    private func mutate(_ identities: [String: Identity], _ nums: [String], _ mutator: (String, inout JSONObject) -> Void) throws {
        try FileLock(lockPath).hold {
            var rows = readRows()
            for num in nums {
                guard let identity = identities[num] else { continue }
                var row = Self.matches(rows[num], identity) ? rows[num]!.objectValue! : Self.freshRow(identity)
                mutator(num, &row)
                rows[num] = .object(row)
            }
            try writeRows(rows)
        }
    }

    /// Atomically win the right to fetch: eligibility is re-checked and a
    /// bounded lease stamped in one locked pass.
    func reserve(_ nums: [String], _ identities: [String: Identity], respectPlans: Bool, repairOverslept: Bool = false) throws -> [String: String] {
        guard !nums.isEmpty else { return [:] }
        let now = clock()
        var won: [String: String] = [:]
        try FileLock(lockPath).hold {
            var rows = readRows()
            for num in nums {
                guard let identity = identities[num] else { continue }
                var row: JSONObject
                if Self.matches(rows[num], identity), let existing = rows[num]?.objectValue {
                    guard Self.rowEligible(existing, now: now, respectPlans: respectPlans, repairOverslept: repairOverslept) else { continue }
                    row = existing
                } else {
                    row = Self.freshRow(identity)
                }
                let claimID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                row["lastAttemptAt"] = .double(now)
                row["claimId"] = .string(claimID)
                row["claimUntil"] = .double(now + Self.claimTTL)
                rows[num] = .object(row)
                won[num] = claimID
            }
            if !won.isEmpty { try writeRows(rows) }
        }
        return won
    }

    /// Merge outcomes fenced by the leases that produced them; returns the
    /// accepted slots.
    @discardableResult
    func record(
        _ outcomes: [String: FetchRecord],
        _ identities: [String: Identity],
        claims: [String: String]?,
        plans: [String: (Double?, Double?)]? = nil
    ) throws -> Set<String> {
        guard !outcomes.isEmpty else { return [] }
        let now = clock()
        var accepted = Set<String>()
        try FileLock(lockPath).hold {
            var rows = readRows()
            for (num, rec) in outcomes.sorted(by: { $0.key < $1.key }) {
                guard let identity = identities[num] else { continue }
                var row: JSONObject
                if let claims {
                    guard let expected = claims[num], Self.matches(rows[num], identity),
                          let existing = rows[num]?.objectValue,
                          existing["claimId"] == .string(expected) else { continue }
                    row = existing
                } else if let existing = rows[num]?.objectValue, let claimID = existing["claimId"], !claimID.isNull,
                          now < (Self.num(existing["claimUntil"]) ?? 0) {
                    continue
                } else if Self.matches(rows[num], identity), let existing = rows[num]?.objectValue {
                    row = existing
                } else {
                    row = Self.freshRow(identity)
                }

                accepted.insert(num)
                row["claimId"] = .null
                row["claimUntil"] = .double(0)
                if rec.sentinel == nil {
                    row["lastAttemptAt"] = .double(now)
                    if rec.error == nil {
                        row["lastGood"] = rec.usage ?? .null
                        row["fetchedAt"] = .double(now)
                        if let plan = plans?[num] {
                            row["nextPollAt"] = plan.0.map { .double($0) } ?? .null
                            row["pollIntervalS"] = plan.1.map { .double($0) } ?? .null
                        }
                        row["consecutiveFailures"] = .int(0)
                        row["lastError"] = .null
                        row["backoffUntil"] = .null
                        row["authDeadStrikes"] = .int(0)
                    } else if let error = rec.error {
                        let failures = Self.pyInt(row["consecutiveFailures"]) + 1
                        row["consecutiveFailures"] = .int(failures)
                        row["lastError"] = .string(error)
                        if error == "http-429" { row["last429At"] = .double(now) }
                        row["backoffUntil"] = .double(now + Self.failureBackoff(
                            failures, retryAfter: rec.retryAfter, rateLimited: error == "http-429"
                        ))
                        if Self.permanentAuthErrors.contains(error) {
                            row["authDeadStrikes"] = .int(Self.pyInt(row["authDeadStrikes"]) + 1)
                            row["struckFingerprint"] = rec.struckFp.map { .string($0) } ?? .null
                        }
                    }
                }
                rows[num] = .object(row)
            }
            if !accepted.isEmpty { try writeRows(rows) }
        }
        return accepted
    }

    func setPollPlan(_ plans: [String: (Double?, Double?)], _ identities: [String: Identity]) throws {
        guard !plans.isEmpty else { return }
        try mutate(identities, Array(plans.keys)) { num, row in
            let plan = plans[num]!
            row["nextPollAt"] = plan.0.map { .double($0) } ?? .null
            row["pollIntervalS"] = plan.1.map { .double($0) } ?? .null
        }
    }

    /// Lift the dead-token quarantine after a re-login rewrote the credential.
    func clearDeadToken(_ nums: [String], _ identities: [String: Identity]) throws {
        guard !nums.isEmpty else { return }
        try mutate(identities, nums) { _, row in
            row["claimId"] = .null
            row["claimUntil"] = .double(0)
            row["authDeadStrikes"] = .int(0)
            row["struckFingerprint"] = .null
            row["consecutiveFailures"] = .int(0)
            row["lastError"] = .null
            row["backoffUntil"] = .null
        }
    }
}

/// `settings.atomic_write_json`: writes THROUGH a symlink, hardens the
/// parent to 0700 and the file to 0600, `indent=2`.
enum AtomicJSON {
    static func write(_ value: JSONValue, to path: URL) throws {
        var target = path
        // os.path.realpath, which also follows a dangling link.
        for _ in 0..<40 {
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { break }
            target = URL(fileURLWithPath: dest, relativeTo: target.deletingLastPathComponent()).standardizedFileURL
        }
        try FS.mkdirs(target.deletingLastPathComponent())
        try FS.chmod(path.deletingLastPathComponent(), 0o700)
        try FS.atomicWrite(Data(value.serialized(indent: 2).utf8), to: target)
    }
}
