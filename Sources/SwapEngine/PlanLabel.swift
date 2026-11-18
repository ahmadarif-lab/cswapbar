import Foundation

/// The Claude subscription plan of a stored login, read from the
/// `oauthAccount` block Claude Code keeps in its config. The rate-limit tier
/// tells the Max tiers apart (`default_claude_max_5x` / `default_claude_max_20x`).
/// The billing period (monthly or annual) is not part of this block, so it is
/// not shown.
enum PlanLabel {
    static func from(_ oauthAccount: JSONObject?) -> String? {
        guard let oauthAccount else { return nil }
        let type = oauthAccount["organizationType"]?.stringValue ?? ""
        let tier = [oauthAccount["organizationRateLimitTier"]?.stringValue, oauthAccount["userRateLimitTier"]?.stringValue]
            .compactMap { $0 }.joined(separator: " ")
        switch type {
        case "claude_max":
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }

    static func from(configText text: String) -> String? {
        guard !text.isEmpty, let obj = try? JSONValue.parse(Data(text.utf8)).objectValue else { return nil }
        return from(obj["oauthAccount"]?.objectValue)
    }
}
