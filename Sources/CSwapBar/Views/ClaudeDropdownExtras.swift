import SwiftUI

/// Claude's warm-up + account-management sections, appended below the
/// account list in its dropdown (`ProviderDropdownView`'s `extraContent`).
struct ClaudeDropdownExtras: View {
    @ObservedObject var provider: ClaudeProvider

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Warm-up")
        ActionRow(
            icon: "flame",
            title: provider.isWarmingUp ? "Warming up…" : "Warm up all accounts",
            subtitle: warmupSubtitle,
            tint: Theme.accent,
            disabled: provider.isWarmingUp || provider.accounts.count < 2
        ) {
            Task { await provider.warmupAll() }
        }

        SectionDivider()
        SectionHeader(title: "Manage")
        ActionRow(icon: "person.badge.plus", title: "Add current login") {
            Task { await provider.addFromCurrentLogin() }
        }
        ActionRow(icon: "key", title: "Add from setup-token…") {
            provider.openAddTokenWindow()
        }
        ActionRow(icon: "arrow.clockwise.circle", title: "Refresh current credentials") {
            Task { await provider.refreshCredentials() }
        }

        ForEach(provider.accounts) { account in
            AccountManageRow(provider: provider, account: account)
        }
    }

    private var warmupSubtitle: String? {
        if let progress = provider.warmupProgress {
            return "\(provider.warmupStatusText ?? "") (\(progress.current)/\(progress.total))"
        }
        return provider.warmupStatusText
    }
}
