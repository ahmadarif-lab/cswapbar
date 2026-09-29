import SwiftUI

/// Renders one account's usage bars for any provider. The switcher chrome
/// (active checkmark, disabled badge, tap-to-switch, disable/remove context
/// menu) only applies to Claude's multi-account model, so it only appears
/// when `account.claudeDetail` is set and the provider actually supports
/// mutating accounts.
struct AccountRowView<P: Provider>: View {
    @ObservedObject var provider: P
    let account: ProviderAccount
    @State private var isHovering = false

    private var mutating: (any AccountMutating)? { provider as? any AccountMutating }

    var body: some View {
        Group {
            if let detail = account.claudeDetail, let mutating {
                Button {
                    Task { await mutating.switchTo(account) }
                } label: {
                    content(detail: detail)
                }
                .buttonStyle(.plain)
                // Not `.disabled()`: SwiftUI dims a disabled button's whole label, which
                // made the active account (the one that can't be switched to) look
                // faded next to the inactive ones. Block the click without the dimming.
                .allowsHitTesting(!detail.active && !mutating.isBusy(account))
                .contextMenu {
                    Button(detail.isDisabled ? "Enable account" : "Disable account") {
                        Task { await mutating.toggleDisabled(account) }
                    }
                    Button("Remove account", role: .destructive) {
                        Task { await mutating.remove(account) }
                    }
                }
            } else {
                content(detail: nil)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(account.claudeDetail?.active == true ? Theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.2)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .rowHoverBackground(isHovering)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func content(detail: ClaudeAccountDetail?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let detail {
                    ZStack {
                        Circle().fill(detail.active ? Theme.accent : Color.clear)
                        Circle().strokeBorder(detail.active ? Color.clear : Color.secondary.opacity(0.45), lineWidth: 1.3)
                        if detail.active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle = account.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, weight: detail?.active == true ? .semibold : .regular))
                            .foregroundStyle(detail?.active == true ? Theme.accent : Color.secondary.opacity(0.7))
                    }
                }

                Spacer()

                if detail?.isDisabled == true {
                    Text("disabled")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }

                if let mutating, mutating.isBusy(account) {
                    ProgressView().controlSize(.small)
                }
            }

            if !account.pools.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(account.pools) { pool in
                        UsageBarView(pool: pool)
                    }
                    if account.isStale {
                        Text(staleCaption)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .opacity(account.isStale ? 0.7 : 1)
            } else {
                Text(account.statusText ?? "no usage data")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if !account.detailRows.isEmpty {
                quotaDetails
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    private var quotaDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("QUOTA DETAILS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            ForEach(account.detailRows) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    if let secondary = row.secondaryValue {
                        Text(secondary)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// "Last known · 5h 2m ago (unavailable)".
    private var staleCaption: String {
        var text = "Last known"
        if let age = account.staleAgeSeconds {
            let minutes = Int(age / 60)
            let ago = minutes < 1 ? "just now"
                : minutes < 60 ? "\(minutes)m ago"
                : minutes % 60 == 0 ? "\(minutes / 60)h ago"
                : "\(minutes / 60)h \(minutes % 60)m ago"
            text += " · \(ago)"
        }
        if let status = account.statusText {
            text += " (\(status.replacingOccurrences(of: "_", with: " ")))"
        }
        return text
    }
}
