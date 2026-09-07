import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var busyNumbers: Set<Int> = []

    @Published private(set) var isWarmingUp = false
    @Published private(set) var warmupStatusText: String?
    @Published private(set) var warmupProgress: (current: Int, total: Int)?

    private let cli = CswapCLI.shared
    private var refreshTask: Task<Void, Never>?

    var activeAccount: Account? { accounts.first(where: \.active) }

    func startAutoRefresh(interval: TimeInterval = 30) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await cli.list()
            accounts = response.accounts.sorted { $0.number < $1.number }
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    // MARK: - Actions (thin wrappers over the real `cswap` commands)

    func switchTo(_ account: Account) async {
        guard !account.active else { return }
        await withBusy(account.number) { try await self.cli.switchTo(String(account.number)) }
    }

    func toggleDisabled(_ account: Account) async {
        await withBusy(account.number) {
            if account.isDisabled {
                try await self.cli.enable(account.number)
            } else {
                try await self.cli.disable(account.number)
            }
        }
    }

    func remove(_ account: Account) async {
        await withBusy(account.number) { try await self.cli.remove(account.number) }
    }

    func refreshCredentials() async {
        await withBusy(activeAccount?.number) { try await self.cli.addCurrentLogin() }
    }

    func addFromCurrentLogin() async {
        await withBusy(nil) { try await self.cli.addCurrentLogin() }
    }

    func addToken(_ token: String, email: String?) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await withBusy(nil) { try await self.cli.addToken(trimmed, email: email) }
    }

    // MARK: - Warm-up all accounts
    // Faithful port of the `claude-warmup` zsh function: rotate through every
    // managed account, send a throwaway `claude -p "halo"`, then switch back.

    func warmupAll() async {
        guard !isWarmingUp else { return }
        let ordered = accounts.sorted { $0.number < $1.number }
        guard ordered.count > 1 else {
            warmupStatusText = "Only one managed account -- nothing to warm up."
            return
        }
        let originalNumber = activeAccount?.number ?? ordered.first?.number

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
                try await cli.switchTo(String(account.number))
            } catch {
                errorMessage = error.localizedDescription
                continue
            }
            warmupStatusText = "Sending warm-up message to \(account.displayName)…"
            _ = try? await cli.claude(["-p", "halo"])
        }

        if let originalNumber {
            warmupStatusText = "Switching back to original account…"
            try? await cli.switchTo(String(originalNumber))
        }

        warmupStatusText = "Warm-up complete."
        await refresh()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if warmupStatusText == "Warm-up complete." {
            warmupStatusText = nil
        }
    }

    func isBusy(_ account: Account) -> Bool { busyNumbers.contains(account.number) }

    func openAddTokenWindow() {
        WindowPresenter.shared.show(id: AddAccountSheet.windowID, title: "Add account", size: NSSize(width: 320, height: 200)) {
            AddAccountSheet().environmentObject(self)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
