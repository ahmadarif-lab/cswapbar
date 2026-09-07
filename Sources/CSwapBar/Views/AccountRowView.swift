import SwiftUI

struct AccountRowView: View {
    @EnvironmentObject var state: AppState
    let account: Account
    @State private var isHovering = false

    var body: some View {
        Button {
            Task { await state.switchTo(account) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(account.active ? Theme.accent : Color.clear)
                        Circle()
                            .strokeBorder(account.active ? Color.clear : Color.secondary.opacity(0.45), lineWidth: 1.3)
                        if account.active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(account.active ? "Active · Slot \(account.number)" : "Slot \(account.number)")
                            .font(.system(size: 10, weight: account.active ? .semibold : .regular))
                            .foregroundStyle(account.active ? Theme.accent : Color.secondary.opacity(0.7))
                    }

                    Spacer()

                    if account.isDisabled {
                        Text("disabled")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }

                    if state.isBusy(account) {
                        ProgressView().controlSize(.small)
                    }
                }

                if let usage = account.usage, account.usageStatus == "ok" {
                    VStack(alignment: .leading, spacing: 7) {
                        UsageBarView(label: "Session (5h)", window: usage.fiveHour)
                        UsageBarView(label: "Weekly (7d)", window: usage.sevenDay)
                    }
                } else {
                    Text(account.usageStatus ?? "no usage data")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not `.disabled()`: SwiftUI dims a disabled button's whole label, which
        // made the active account (the one that can't be switched to) look
        // faded next to the inactive ones. Block the click without the dimming.
        .allowsHitTesting(!account.active && !state.isBusy(account))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(account.active ? Theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.2)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .rowHoverBackground(isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(account.isDisabled ? "Enable account" : "Disable account") {
                Task { await state.toggleDisabled(account) }
            }
            Button("Remove account", role: .destructive) {
                Task { await state.remove(account) }
            }
        }
    }
}
