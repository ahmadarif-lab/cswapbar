import AppKit
import SwiftUI

/// Generalizes the old single-provider `PopoverView` into the dropdown any
/// provider's status-bar slot opens. Provider-specific bottom content
/// (Claude's warm-up/manage sections, z.ai/Antigravity's "add account"
/// prompt) is supplied by the call site rather than branched on internally.
struct ProviderDropdownView<P: Provider, Extra: View>: View {
    @ObservedObject var provider: P
    @ViewBuilder var extraContent: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 0) {
                if !provider.isConfigured {
                    Text("Not configured yet. Open Settings to add an account.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                } else if provider.accounts.isEmpty {
                    Text(provider.isRefreshing ? "Loading…" : "No usage data yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                } else {
                    ForEach(provider.accounts) { account in
                        AccountRowView(provider: provider, account: account)
                    }
                }

                extraContent()
            }

            SectionDivider()
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.cardBackground(for: provider.kind.accent))
        .background(.regularMaterial)
        // Freshen on open; the periodic poll itself lives in ProviderStore.
        .task {
            await provider.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                ProviderIconView(source: provider.kind.iconSource, size: 14)
                    .foregroundStyle(provider.kind.accent)
                Text(provider.kind.title)
                    .font(.system(size: 14, weight: .bold))
                if let version = Updater.currentVersion {
                    Text("v\(version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if provider.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Text(lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let error = provider.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.high)
                        .lineLimit(1)
                        .help(error)
                        .copyableOnContextMenu(error)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var lastUpdatedText: String {
        guard let date = provider.lastUpdated else { return "Not yet updated" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    /// Update checking lives only in Settings > General now (see
    /// `AboutHeader`) -- repeating it in every provider's dropdown was as
    /// redundant as the "Start at login" row that used to sit here too.
    private var footer: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "arrow.clockwise", title: "Refresh now") {
                Task { await provider.refresh() }
            }
            ActionRow(icon: "gearshape", title: "Settings…") {
                SettingsWindow.show()
            }
            ActionRow(icon: "power", title: "Quit", tint: Theme.high) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}
