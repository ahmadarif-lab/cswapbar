import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: Updater
    @State private var startAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 0) {
                if state.accounts.isEmpty {
                    Text(state.isRefreshing ? "Loading accounts…" : "No managed accounts yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                } else {
                    ForEach(state.accounts) { account in
                        AccountRowView(account: account)
                    }
                }

                SectionDivider()
                SectionHeader(title: "Warm-up")
                ActionRow(
                    icon: "flame",
                    title: state.isWarmingUp ? "Warming up…" : "Warm up all accounts",
                    subtitle: warmupSubtitle,
                    tint: Theme.accent,
                    disabled: state.isWarmingUp || state.accounts.count < 2
                ) {
                    Task { await state.warmupAll() }
                }

                SectionDivider()
                SectionHeader(title: "Manage")
                ActionRow(icon: "person.badge.plus", title: "Add current login") {
                    Task { await state.addFromCurrentLogin() }
                }
                ActionRow(icon: "key", title: "Add from setup-token…") {
                    state.openAddTokenWindow()
                }
                ActionRow(icon: "arrow.clockwise.circle", title: "Refresh current credentials") {
                    Task { await state.refreshCredentials() }
                }

                ForEach(state.accounts) { account in
                    AccountManageRow(account: account)
                }
            }

            SectionDivider()
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.cardBackground)
        .background(.regularMaterial)
        // Freshen on open; the periodic poll itself lives in AppState.init.
        // Login-item status is re-read too, since System Settings can change it.
        .task {
            startAtLogin = LoginItem.isEnabled
            await state.refresh()
        }
    }

    private var warmupSubtitle: String? {
        if let progress = state.warmupProgress {
            return "\(state.warmupStatusText ?? "") (\(progress.current)/\(progress.total))"
        }
        return state.warmupStatusText
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text("Claude Swap")
                    .font(.system(size: 14, weight: .bold))
                if let version = Updater.currentVersion {
                    Text("v\(version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Text(lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let error = state.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.high)
                        .lineLimit(1)
                        .help(error)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var lastUpdatedText: String {
        guard let date = state.lastUpdated else { return "Not yet updated" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if Updater.currentVersion != nil {
                updateRow
            }
            ActionRow(
                icon: startAtLogin ? "checkmark.square" : "square",
                title: "Start at login"
            ) {
                LoginItem.setEnabled(!startAtLogin)
                startAtLogin = LoginItem.isEnabled
            }
            ActionRow(icon: "arrow.clockwise", title: "Refresh now") {
                Task { await state.refresh() }
            }
            ActionRow(icon: "power", title: "Quit", tint: Theme.high) {
                state.quit()
            }
        }
        .padding(.vertical, 4)
    }

    /// "Check for updates" until a newer release turns up, then the button
    /// that installs it.
    @ViewBuilder
    private var updateRow: some View {
        if let release = updater.availableUpdate {
            ActionRow(
                icon: "arrow.down.circle.fill",
                title: updater.isUpdating ? "Updating to v\(release.version)…" : "Update to v\(release.version)",
                subtitle: updater.progressText ?? updater.errorMessage ?? "You have v\(Updater.currentVersion ?? "")",
                tint: Theme.accent,
                disabled: updater.isUpdating
            ) {
                Task { await updater.update() }
            }
        } else {
            ActionRow(
                icon: "arrow.down.circle",
                title: updater.isChecking ? "Checking for updates…" : "Check for updates",
                subtitle: updater.errorMessage ?? (updater.lastChecked == nil ? nil : "Up to date"),
                disabled: updater.isChecking
            ) {
                Task { await updater.check() }
            }
        }
    }
}
