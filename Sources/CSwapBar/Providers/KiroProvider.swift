import Foundation
import KiroEngine
import ProviderKit

/// Kiro is a flat-rate subscription with a single monthly credit pool, so
/// this shows one window (how much of that pool is spent) instead of a
/// balance. The number comes from the `kiro-cli` the user is already signed
/// into, so there is nothing to paste here and no add sheet; the quota is
/// read-only and refills monthly, so there is no warm-up either.
@MainActor
final class KiroProvider: ObservableObject {
    let kind: ProviderKind = .kiro

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    /// Published rather than derived on demand: resolving it stats the
    /// filesystem, and a view body is the wrong place for that.
    @Published private(set) var isConfigured = false
    @Published private(set) var binaryPath: String?

    private let engine = KiroEngine.shared
    private var refreshTask: Task<Void, Never>?

    init() {
        // Read the CLI's location once up front: the Settings page shows its
        // state before any refresh has run, and a provider that isn't
        // switched on in the menu bar never gets one.
        loadCLI()
    }

    private func loadCLI() {
        binaryPath = engine.binaryPath
        isConfigured = binaryPath != nil
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
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
        // Pick up a CLI installed since the last look (`brew install` run
        // while CSwapBar was open) before deciding anything.
        loadCLI()
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
            DiagnosticLog.log("kiro", "refresh failed: \(DiagnosticLog.describe(error))")
        }
    }

    private static func adapt(_ summary: KiroUsageSummary) -> ProviderAccount {
        let pool = UsagePool(
            id: "credits",
            window: .other,
            pctUsed: summary.pctUsed,
            resetsAt: summary.resetsAt,
            // Its own name rather than the generic "Monthly": the pool is
            // counted in credits, not percent-of-window.
            labelOverride: summary.unit.map { "Monthly \($0.lowercased())" } ?? "Monthly usage"
        )
        let detailRows: [ProviderDetailRow] = {
            guard let used = summary.used, let limit = summary.limit else { return [] }
            return [
                ProviderDetailRow(
                    label: "\(summary.unit ?? "Credits") covered in plan",
                    value: "\(format(used)) of \(format(limit))"
                )
            ]
        }()
        return ProviderAccount(
            id: "kiro",
            displayName: "Kiro",
            subtitle: summary.planName,
            pools: [pool],
            detailRows: detailRows
        )
    }

    /// Whole numbers stay whole ("1000"), fractions keep a hundredth
    /// ("160.89") -- the CLI's own precision, without leaning on the user's
    /// locale for a decimal comma.
    private static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", rounded)
            : String(format: "%.2f", rounded)
    }
}

extension KiroProvider: Provider {}
