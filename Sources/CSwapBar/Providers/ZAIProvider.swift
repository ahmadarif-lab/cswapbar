import Foundation
import ProviderKit
import ZAIEngine

@MainActor
final class ZAIProvider: ObservableObject, Provider {
    let kind: ProviderKind = .zai

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?

    private let engine = ZAIEngine.shared
    private var refreshTask: Task<Void, Never>?

    var isConfigured: Bool { engine.hasStoredCredential() }

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
            DiagnosticLog.log("zai", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    private static func adapt(_ summary: ZAIAccountSummary) -> ProviderAccount {
        let pools = summary.pools.map { pool -> UsagePool in
            let id: String
            let window: PoolWindow
            switch pool.kind {
            case .primary: id = "primary"; window = .fiveHour
            case .secondary: id = "secondary"; window = .weekly
            case .mcp: id = "mcp"; window = .other
            }
            return UsagePool(id: id, window: window, pctUsed: pool.pctUsed, resetsAt: pool.resetsAt, labelOverride: pool.label)
        }
        let detailRows = summary.detailRows.map { ProviderDetailRow(label: $0.label, value: $0.value, secondaryValue: $0.secondaryValue) }
        return ProviderAccount(
            id: "zai", displayName: "z.ai account", subtitle: summary.planName.map { "\($0) plan" },
            pools: pools, detailRows: detailRows
        )
    }

    // MARK: - Credential management

    func setAPIKey(_ apiKey: String, region: ZAIRegion) async {
        do {
            try engine.setAPIKey(apiKey, region: region)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLog.log("zai", "setting API key failed: \(DiagnosticLog.describe(error))")
        }
    }

    func removeCredential() {
        try? engine.removeStoredCredential()
        accounts = []
        lastUpdated = nil
    }

    var region: ZAIRegion { engine.region }
}
