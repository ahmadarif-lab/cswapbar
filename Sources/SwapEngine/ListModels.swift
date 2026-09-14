import Foundation

/// The `cswap list --json` (schema 1) shapes the app renders.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let pct: Double?
    public let resetsAt: String?
    public let countdown: String?
    public let clock: String?
    public let expectedPct: Double?
    public let aheadOfPace: Bool?
    public let projectedExhaustionAt: String?
    public let willLastToReset: Bool?

    public init(
        pct: Double?, resetsAt: String?, countdown: String?, clock: String?,
        expectedPct: Double? = nil, aheadOfPace: Bool? = nil,
        projectedExhaustionAt: String? = nil, willLastToReset: Bool? = nil
    ) {
        self.pct = pct
        self.resetsAt = resetsAt
        self.countdown = countdown
        self.clock = clock
        self.expectedPct = expectedPct
        self.aheadOfPace = aheadOfPace
        self.projectedExhaustionAt = projectedExhaustionAt
        self.willLastToReset = willLastToReset
    }
}

public struct Usage: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let number: Int
    public let email: String
    public let organizationName: String?
    public let organizationUuid: String?
    public let isOrganization: Bool?
    public let active: Bool
    public let usageStatus: String?
    public let usage: Usage?
    public let usageFetchedAt: String?
    public let usageAgeSeconds: Double?
    public let disabled: Bool?
    public let alias: String?

    public init(
        number: Int, email: String, organizationName: String?, organizationUuid: String?,
        isOrganization: Bool?, active: Bool, usageStatus: String?, usage: Usage?,
        usageFetchedAt: String?, usageAgeSeconds: Double?, disabled: Bool?, alias: String?
    ) {
        self.number = number
        self.email = email
        self.organizationName = organizationName
        self.organizationUuid = organizationUuid
        self.isOrganization = isOrganization
        self.active = active
        self.usageStatus = usageStatus
        self.usage = usage
        self.usageFetchedAt = usageFetchedAt
        self.usageAgeSeconds = usageAgeSeconds
        self.disabled = disabled
        self.alias = alias
    }

    public var id: Int { number }

    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return email
    }

    public var isDisabled: Bool { disabled ?? false }
}

public struct ListResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let activeAccountNumber: Int?
    public let accounts: [Account]

    public init(schemaVersion: Int, activeAccountNumber: Int?, accounts: [Account]) {
        self.schemaVersion = schemaVersion
        self.activeAccountNumber = activeAccountNumber
        self.accounts = accounts
    }
}
