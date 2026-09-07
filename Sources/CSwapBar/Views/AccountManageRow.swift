import SwiftUI

/// Compact per-account row with disable/enable + remove actions, separate
/// from the big switchable AccountRowView above so nothing nests buttons.
struct AccountManageRow: View {
    @EnvironmentObject var state: AppState
    let account: Account
    @State private var isHovering = false
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 8) {
            Text(account.displayName)
                .font(.system(size: 11.5))
                .foregroundStyle(account.isDisabled ? .tertiary : .primary)
                .lineLimit(1)
            Spacer()

            if state.isBusy(account) {
                ProgressView().controlSize(.small)
            } else if confirmingRemove {
                Text("Remove?")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.high)
                Button {
                    Task {
                        await state.remove(account)
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
                    Task { await state.toggleDisabled(account) }
                } label: {
                    Image(systemName: account.isDisabled ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.plain)
                .help(account.isDisabled ? "Enable" : "Disable")

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
