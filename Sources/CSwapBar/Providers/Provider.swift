import Foundation

@MainActor
protocol Provider: AnyObject, ObservableObject {
    var kind: ProviderKind { get }
    var accounts: [ProviderAccount] { get }
    var lastUpdated: Date? { get }
    var isRefreshing: Bool { get }
    var errorMessage: String? { get }
    /// Shown instead of an account list before any credential is configured.
    var isConfigured: Bool { get }

    func refresh() async
    func startAutoRefresh(interval: TimeInterval)
    func stopAutoRefresh()
}

/// The Claude-only account-management surface (multiple accounts, switching,
/// warm-up). Antigravity/z.ai hold a single read-only credential in v1, so
/// views branch on `provider as? any AccountMutating` rather than forcing
/// every provider through this richer, Claude-shaped UI.
@MainActor
protocol AccountMutating: Provider {
    func switchTo(_ account: ProviderAccount) async
    func toggleDisabled(_ account: ProviderAccount) async
    func remove(_ account: ProviderAccount) async
    func isBusy(_ account: ProviderAccount) -> Bool
}
