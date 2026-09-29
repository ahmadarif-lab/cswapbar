import AppKit
import Foundation
import SwapEngine

/// Behavior-preserving wrap of the old `AppState`: same engine calls, same
/// polling, same warm-up flow, adapted to the generic `Provider` shape so
/// Claude sits alongside Antigravity/z.ai in `ProviderStore`. Claude-only
/// extras (add-account, warm-up) live as plain methods beyond the
/// `AccountMutating` protocol; views reach them via the concrete type.
@MainActor
final class ClaudeProvider: ObservableObject, AccountMutating {
    let kind: ProviderKind = .claude

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var busyNumbers: Set<Int> = []

    @Published private(set) var isWarmingUp = false
    @Published private(set) var warmupStatusText: String?
    @Published private(set) var warmupProgress: (current: Int, total: Int)?

    var isConfigured: Bool { true }

    private let engine = AccountEngine.shared
    private let shell = Shell.shared
    private var refreshTask: Task<Void, Never>?
    /// The raw engine accounts behind the current `accounts`, kept so
    /// account-mutating calls can look up a `SwapEngine.Account` by id
    /// without re-threading engine types through the generic view layer.
    private var rawAccounts: [Account] = []

    var activeRawAccount: Account? { rawAccounts.first(where: \.active) }

    func startAutoRefresh(interval: TimeInterval = 30) {
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
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await engine.list()
            let sorted = response.accounts.sorted { $0.number < $1.number }
            rawAccounts = sorted
            accounts = sorted.map(Self.adapt)
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func adapt(_ account: Account) -> ProviderAccount {
        let detail = ClaudeAccountDetail(number: account.number, active: account.active, isDisabled: account.isDisabled)
        if let usage = account.usage, account.usageStatus == "ok" {
            return ProviderAccount(
                id: String(account.number), displayName: account.displayName,
                subtitle: account.active ? "Active · Slot \(account.number)" : "Slot \(account.number)",
                pools: pools(from: usage), claudeDetail: detail
            )
        }
        if let usage = account.lastGoodUsage {
            return ProviderAccount(
                id: String(account.number), displayName: account.displayName,
                subtitle: account.active ? "Active · Slot \(account.number)" : "Slot \(account.number)",
                pools: pools(from: usage), statusText: account.usageStatus,
                isStale: true, staleAgeSeconds: account.lastGoodAgeSeconds, claudeDetail: detail
            )
        }
        return ProviderAccount(
            id: String(account.number), displayName: account.displayName,
            subtitle: account.active ? "Active · Slot \(account.number)" : "Slot \(account.number)",
            statusText: account.usageStatus ?? "no usage data", claudeDetail: detail
        )
    }

    private static func pools(from usage: Usage) -> [UsagePool] {
        [
            UsagePool(id: "5h", poolName: nil, window: .fiveHour, pctUsed: usage.fiveHour?.pct, resetsAt: usage.fiveHour?.resetsAt.flatMap(parseISO)),
            UsagePool(id: "weekly", poolName: nil, window: .weekly, pctUsed: usage.sevenDay?.pct, resetsAt: usage.sevenDay?.resetsAt.flatMap(parseISO)),
        ]
    }

    /// `SwapEngine.UsageWindow.resetsAt` is server-formatted ISO 8601 UTC --
    /// usually with fractional seconds (Anthropic's API includes them), so
    /// the fractional-seconds formatter has to be tried first: plain
    /// `.withInternetDateTime` rejects a string with a fractional part
    /// outright and returns nil, which silently dropped every reset-time
    /// display (`UsageBarView` only renders "Resets in…"/the clock when
    /// `resetsAt` is non-nil).
    private static func parseISO(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    private func withBusy(_ number: Int?, _ body: () async throws -> Void) async {
        if let number { busyNumbers.insert(number) }
        defer { if let number { busyNumbers.remove(number) } }
        do {
            try await body()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rawAccount(for account: ProviderAccount) -> Account? {
        guard let number = Int(account.id) else { return nil }
        return rawAccounts.first { $0.number == number }
    }

    // MARK: - AccountMutating

    func switchTo(_ account: ProviderAccount) async {
        guard let raw = rawAccount(for: account), !raw.active else { return }
        await withBusy(raw.number) { try await self.engine.switchTo(raw.number) }
    }

    func toggleDisabled(_ account: ProviderAccount) async {
        guard let raw = rawAccount(for: account) else { return }
        await withBusy(raw.number) {
            if raw.isDisabled {
                try await self.engine.enable(raw.number)
            } else {
                try await self.engine.disable(raw.number)
            }
        }
    }

    func remove(_ account: ProviderAccount) async {
        guard let raw = rawAccount(for: account) else { return }
        await withBusy(raw.number) { try await self.engine.remove(raw.number) }
    }

    func isBusy(_ account: ProviderAccount) -> Bool {
        guard let number = Int(account.id) else { return false }
        return busyNumbers.contains(number)
    }

    // MARK: - Claude-only extras

    func refreshCredentials() async {
        await withBusy(activeRawAccount?.number) { try await self.engine.addCurrentLogin() }
    }

    func addFromCurrentLogin() async {
        await withBusy(nil) { try await self.engine.addCurrentLogin() }
    }

    func addToken(_ token: String, email: String?) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await withBusy(nil) { try await self.engine.addToken(trimmed, email: email) }
    }

    // MARK: - Warm-up all accounts
    // Faithful port of the `claude-warmup` zsh function: rotate through every
    // managed account, send a throwaway `claude -p "halo"`, then switch back.

    func warmupAll() async {
        guard !isWarmingUp else { return }
        let ordered = rawAccounts.sorted { $0.number < $1.number }
        guard ordered.count > 1 else {
            warmupStatusText = "Only one managed account -- nothing to warm up."
            return
        }
        let originalNumber = activeRawAccount?.number ?? ordered.first?.number

        isWarmingUp = true
        warmupStatusText = nil
        defer {
            isWarmingUp = false
            warmupProgress = nil
        }

        for (index, account) in ordered.enumerated() {
            if Task.isCancelled { break }
            warmupProgress = (index + 1, ordered.count)
            warmupStatusText = "Switching to \(account.displayName)…"
            do {
                try await engine.switchTo(account.number)
            } catch {
                errorMessage = error.localizedDescription
                continue
            }
            warmupStatusText = "Sending warm-up message to \(account.displayName)…"
            _ = try? await shell.claude(["-p", "halo"])
        }

        if let originalNumber {
            warmupStatusText = "Switching back to original account…"
            try? await engine.switchTo(originalNumber)
        }

        warmupStatusText = "Warm-up complete."
        await refresh()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if warmupStatusText == "Warm-up complete." {
            warmupStatusText = nil
        }
    }

    func openAddTokenWindow() {
        WindowPresenter.shared.show(id: AddAccountSheet.windowID, title: "Add account", size: NSSize(width: 320, height: 200)) {
            AddAccountSheet().environmentObject(self)
        }
    }
}
