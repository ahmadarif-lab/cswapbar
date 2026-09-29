import AntigravityEngine
import Foundation
import ProviderKit

@MainActor
final class AntigravityProvider: ObservableObject, WarmingUp {
    let kind: ProviderKind = .antigravity

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var isWarmingUp = false
    @Published private(set) var warmupStatusText: String?
    /// Non-nil while auto-detect/manual-token entry is running, surfaced by
    /// the "Add account" sheet.
    @Published private(set) var isConnecting = false

    private let engine = AntigravityEngine.shared
    private var refreshTask: Task<Void, Never>?

    /// True once a quota fetch has any hope of succeeding: either a CLI
    /// session's local hub is running right now (no setup needed), or the
    /// user has connected an account for the OAuth fallback.
    var isConfigured: Bool { engine.canFetchRightNow() }
    /// Whether a fallback OAuth account has actually been connected --
    /// distinct from `isConfigured`, which is also true whenever a CLI hub
    /// just happens to be running right now, with nothing to remove.
    var hasStoredCredential: Bool { engine.hasStoredCredential() }

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
        engine.stopManagedHub()
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
            let summary = try await engine.currentAccount()
            accounts = [Self.adapt(summary)]
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("antigravity", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    private static func adapt(_ summary: AntigravityAccountSummary) -> ProviderAccount {
        let pools = summary.pools.enumerated().map { index, pool in
            UsagePool(
                id: "\(pool.poolName)-\(pool.windowLabel)-\(index)",
                poolName: pool.poolName,
                window: pool.windowLabel == "Weekly" ? .weekly : .fiveHour,
                pctUsed: pool.pctUsed, resetsAt: pool.resetsAt
            )
        }
        return ProviderAccount(id: "antigravity", displayName: "Antigravity account", pools: pools)
    }

    // MARK: - Warm-up

    func warmup() async {
        guard !isWarmingUp, isConfigured else { return }
        isWarmingUp = true
        warmupStatusText = "Sending warm-up message…"
        defer { isWarmingUp = false }
        do {
            let engine = engine
            try await Task.detached { try engine.sendWarmupMessages() }.value
            warmupStatusText = "Warm-up complete."
        } catch {
            warmupStatusText = "Warm-up failed: \(error.localizedDescription)"
            DiagnosticLog.log("antigravity", "warm-up failed: \(DiagnosticLog.describe(error))")
        }
        await refresh()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if warmupStatusText == "Warm-up complete." {
            warmupStatusText = nil
        }
    }

    // MARK: - Credential management

    func autoDetect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await engine.autoDetectAndStore()
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("antigravity", "auto-detect failed: \(DiagnosticLog.describe(error))")
        }
    }

    func connectWithManualToken(_ token: String) async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await engine.storeManualRefreshToken(token)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("antigravity", "manual token connect failed: \(DiagnosticLog.describe(error))")
        }
    }

    func removeCredential() {
        try? engine.removeStoredCredential()
        accounts = []
        lastUpdated = nil
    }
}
