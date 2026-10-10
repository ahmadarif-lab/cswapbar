import CodexEngine
import Foundation
import ProviderKit

/// Codex runs on the ChatGPT plan's own 5-hour and weekly windows, so this
/// shows those two bars. The login is whatever the Codex CLI itself stored,
/// so there is nothing to paste here and no add sheet. Usage is read-only;
/// the one thing CSwapBar sends is the optional warm-up message, which goes
/// through the `codex` CLI so it rides on the CLI's own login.
@MainActor
final class CodexProvider: ObservableObject, WarmingUp {
    let kind: ProviderKind = .codex

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    /// Published rather than derived on demand: reading it hits the disk, and
    /// a view body is the wrong place for that.
    @Published private(set) var isConfigured = false
    @Published private(set) var loginSummary: String?
    @Published private(set) var isWarmingUp = false
    @Published private(set) var warmupStatusText: String?

    private let engine = CodexEngine.shared
    private var refreshTask: Task<Void, Never>?

    init() {
        // Read the login once up front: the Settings page shows its state
        // before any refresh has run, and a provider that isn't switched on
        // in the menu bar never gets one.
        loadLogin()
    }

    private func loadLogin() {
        let login = engine.login()
        isConfigured = login != nil
        let parts = [login?.email, login?.planType.map(Self.capitalized)].compactMap { $0 }
        loginSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func capitalized(_ raw: String) -> String {
        raw.prefix(1).uppercased() + raw.dropFirst()
    }

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
        // Pick up a login made since the last look (`codex login` run while
        // CSwapBar was open) before deciding anything.
        loadLogin()
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
            accounts = [Self.adapt(summary, email: engine.login()?.email)]
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("codex", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    private static func adapt(_ summary: CodexUsageSummary, email: String?) -> ProviderAccount {
        let pools = summary.windows.map { window -> UsagePool in
            let poolWindow: PoolWindow
            switch window.kind {
            case .fiveHour: poolWindow = .fiveHour
            case .weekly: poolWindow = .weekly
            // A window of some other length belongs in the dropdown, not the
            // menu bar's two-bar condensation -- same as z.ai's extra windows.
            case .other: poolWindow = .other
            }
            return UsagePool(
                id: window.kind.label, window: poolWindow, pctUsed: window.pctUsed,
                resetsAt: window.resetsAt, labelOverride: window.kind.label
            )
        }
        var detailRows: [ProviderDetailRow] = []
        if let credits = summary.creditBalance {
            detailRows.append(ProviderDetailRow(label: "Credits", value: credits))
        }
        if summary.isLimitReached {
            detailRows.append(ProviderDetailRow(label: "Status", value: "Limit reached"))
        }
        let subtitle = [summary.planName.map { "\($0) plan" }, email].compactMap { $0 }
        return ProviderAccount(
            id: "codex", displayName: "Codex",
            subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: " · "),
            pools: pools, detailRows: detailRows
        )
    }

    // MARK: - Warm-up

    /// The window is started by a real message, and the only thing that can
    /// send one is the CLI the user is already signed into -- so this shells
    /// out to `codex exec`, the way OpenCode Go's warm-up shells out to
    /// `opencode`.
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
            DiagnosticLog.log("codex", "warm-up failed: \(DiagnosticLog.describe(error))")
        }
        await refresh()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if warmupStatusText == "Warm-up complete." {
            warmupStatusText = nil
        }
    }
}

extension CodexProvider: Provider {}
