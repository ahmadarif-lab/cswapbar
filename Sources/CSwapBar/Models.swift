import Foundation

struct UsageWindow: Codable, Equatable {
    let pct: Double?
    let resetsAt: String?
    let countdown: String?
    let clock: String?
    let expectedPct: Double?
    let aheadOfPace: Bool?
    let projectedExhaustionAt: String?
    let willLastToReset: Bool?
}

struct Usage: Codable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
}

struct Account: Codable, Equatable, Identifiable {
    let number: Int
    let email: String
    let organizationName: String?
    let organizationUuid: String?
    let isOrganization: Bool?
    let active: Bool
    let usageStatus: String?
    let usage: Usage?
    let usageFetchedAt: String?
    let usageAgeSeconds: Double?
    let disabled: Bool?
    let alias: String?

    var id: Int { number }

    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return email
    }

    var isDisabled: Bool { disabled ?? false }
}

struct ListResponse: Codable {
    let schemaVersion: Int
    let activeAccountNumber: Int?
    let accounts: [Account]
}

enum UsageLevel {
    case low, medium, high

    init(pct: Double?) {
        guard let pct else { self = .low; return }
        if pct >= 80 { self = .high }
        else if pct >= 50 { self = .medium }
        else { self = .low }
    }
}
