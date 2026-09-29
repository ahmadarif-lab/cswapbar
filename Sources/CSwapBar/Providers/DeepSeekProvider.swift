import DeepSeekEngine
import Foundation
import ProviderKit

/// DeepSeek is pay-as-you-go: no usage windows (so no bars and no warm-up),
/// just the prepaid credit left on the API key's account.
@MainActor
final class DeepSeekProvider: ObservableObject {
    let kind: ProviderKind = .deepseek

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?

    private let engine = DeepSeekEngine.shared
    private var refreshTask: Task<Void, Never>?

    var isConfigured: Bool { engine.hasStoredCredential() }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard isConfigured else {
            accounts = []
            errorMessage = nil
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await engine.currentBalance()
            accounts = [Self.adapt(summary)]
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("deepseek", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    /// Same wording as CodexBar's DeepSeek card.
    private static func adapt(_ summary: DeepSeekBalanceSummary) -> ProviderAccount {
        let warning: String?
        if summary.total <= 0 {
            warning = "Add credits at platform.deepseek.com"
        } else if !summary.isAvailable {
            warning = "Balance unavailable for API calls"
        } else {
            warning = nil
        }
        let balance = ProviderBalance(
            total: summary.format(summary.total),
            breakdown: "Paid: \(summary.format(summary.toppedUp)) / Granted: \(summary.format(summary.granted))",
            warning: warning
        )
        return ProviderAccount(id: "deepseek", displayName: "DeepSeek account", subtitle: "API balance", balance: balance)
    }

    // MARK: - Credential management

    func setAPIKey(_ apiKey: String) async {
        do {
            try engine.setAPIKey(apiKey)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("deepseek", "setting API key failed: \(DiagnosticLog.describe(error))")
        }
    }

    func removeCredential() {
        try? engine.removeStoredCredential()
        accounts = []
        lastUpdated = nil
        errorMessage = nil
    }
}

extension DeepSeekProvider: Provider {}
