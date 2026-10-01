import Foundation
import OpenCodeGoEngine
import ProviderKit

/// OpenCode Go is a flat-rate subscription, so this shows its three quota
/// windows (5-hour, weekly, monthly) instead of a balance. The credential is
/// whatever OpenCode itself stored, so there is nothing to paste here and no
/// add sheet; the quota is read-only, so there is no warm-up either.
@MainActor
final class OpenCodeGoProvider: ObservableObject, WarmingUp {
    let kind: ProviderKind = .opencodeGo

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    /// Published rather than derived on demand: reading it hits OpenCode's
    /// database, and a view body is the wrong place for that.
    @Published private(set) var isConfigured = false
    @Published private(set) var credentialSource: String?
    @Published private(set) var isWarmingUp = false
    @Published private(set) var warmupStatusText: String?

    private let engine = OpenCodeGoEngine.shared
    private var refreshTask: Task<Void, Never>?

    init() {
        // Read the stored credential once up front: the Settings page shows
        // its state before any refresh has run, and a provider that isn't
        // switched on in the menu bar never gets one.
        loadCredential()
    }

    var credentialFileURL: URL { engine.credentialFileURL }

    private func loadCredential() {
        let credential = engine.credential()
        isConfigured = credential != nil
        credentialSource = credential.map { "\($0.entryName) · \($0.kind.title) · \($0.source.title)" }
    }

    func startAutoRefresh(interval: TimeInterval = 120) {
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
        // Pick up a credential connected since the last look (`opencode auth
        // login` run while CSwapBar was open) before deciding anything.
        engine.reloadCredential()
        let credential = engine.credential()
        isConfigured = credential != nil
        credentialSource = credential.map { "\($0.entryName) · \($0.kind.title) · \($0.source.title)" }

        guard isConfigured else {
            accounts = []
            errorMessage = nil
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await engine.currentUsage()
            accounts = [Self.adapt(summary)]
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("opencode-go", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    private static func adapt(_ summary: OpenCodeGoUsageSummary) -> ProviderAccount {
        let pools = summary.windows.map { window -> UsagePool in
            let poolWindow: PoolWindow
            switch window.kind {
            case .rolling: poolWindow = .fiveHour
            case .weekly: poolWindow = .weekly
            // A third metric belongs in the dropdown, not the menu bar's
            // two-bar condensation -- same treatment as z.ai's MCP window.
            case .monthly: poolWindow = .other
            }
            return UsagePool(
                id: window.kind.rawValue, window: poolWindow, pctUsed: window.pctUsed,
                resetsAt: window.resetsAt, labelOverride: window.kind.label
            )
        }
        // The console route reports dollars; the API-key route doesn't, so
        // these rows simply don't appear there.
        let detailRows = summary.windows.compactMap { window -> ProviderDetailRow? in
            guard let used = window.usedUSD, let limit = window.limitUSD else { return nil }
            return ProviderDetailRow(
                label: "\(window.kind.label) limit",
                value: "\(formatUSD(used)) of \(formatUSD(limit))"
            )
        }
        return ProviderAccount(
            id: "opencode-go", displayName: "OpenCode Go",
            subtitle: summary.planName.map { "\($0) plan" } ?? "Go subscription",
            pools: pools, detailRows: detailRows
        )
    }

    private static func formatUSD(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    // MARK: - Warm-up

    /// The window is started by a real message, and the only thing that can
    /// send one is the CLI the user is already signed into -- so this shells
    /// out to `opencode run`, the way Antigravity's warm-up shells out to
    /// `agy`. It leaves a "CSwapBar warm-up" session behind, the same way
    /// Claude's warm-up leaves a `claude -p` entry behind.
    func warmup() async {
        guard !isWarmingUp, isConfigured else { return }
        isWarmingUp = true
        warmupStatusText = "Sending warm-up message…"
        defer { isWarmingUp = false }
        do {
            let engine = engine
            try await Task.detached { try engine.sendWarmupMessage() }.value
            warmupStatusText = "Warm-up complete."
        } catch {
            warmupStatusText = "Warm-up failed: \(error.localizedDescription)"
            DiagnosticLog.log("opencode-go", "warm-up failed: \(DiagnosticLog.describe(error))")
        }
        await refresh()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if warmupStatusText == "Warm-up complete." {
            warmupStatusText = nil
        }
    }
}

extension OpenCodeGoProvider: Provider {}
