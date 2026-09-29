import SwiftUI

/// Compact per-account row with disable/enable + remove actions, separate
/// from the big switchable AccountRowView above so nothing nests buttons.
/// Claude-only: the provider that owns this row must support account
/// mutation.
struct AccountManageRow: View {
    @ObservedObject var provider: ClaudeProvider
    let account: ProviderAccount
    @State private var isHovering = false
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 8) {
            Text(account.displayName)
                .font(.system(size: 11.5))
                .foregroundStyle(account.claudeDetail?.isDisabled == true ? .tertiary : .primary)
                .lineLimit(1)
            Spacer()

            if provider.isBusy(account) {
                ProgressView().controlSize(.small)
            } else if confirmingRemove {
                Text("Remove?")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.high)
                Button {
                    Task {
                        await provider.remove(account)
                        confirmingRemove = false
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.high)
                .help("Confirm remove")

                Button {
                    confirmingRemove = false
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Button {
                    Task { await provider.toggleDisabled(account) }
                } label: {
                    Image(systemName: account.claudeDetail?.isDisabled == true ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.plain)
                .help(account.claudeDetail?.isDisabled == true ? "Enable" : "Disable")

                Button {
                    confirmingRemove = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .rowHoverBackground(isHovering)
        .onHover { isHovering = $0 }
    }
}
