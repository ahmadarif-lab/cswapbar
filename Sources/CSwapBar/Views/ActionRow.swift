import SwiftUI

struct ActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    /// Short status at the trailing edge, in line with the account rows' icons.
    var detail: String? = nil
    var detailTint: Color = .secondary
    var tint: Color = .primary
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(disabled ? .tertiary : .primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(detailTint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .rowHoverBackground(isHovering)
        .onHover { isHovering = $0 }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct SectionDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}
