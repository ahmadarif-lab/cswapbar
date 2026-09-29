import SwiftUI

/// Thin, fixed-width capsule bar (CodexBar-style). Deliberately not a
/// ProgressView/GeometryReader-based bar: both render taller/thicker than
/// intended here, and GeometryReader specifically breaks layout when this
/// view sits inside certain popover/panel container hierarchies.
struct UsageBarView: View {
    let pool: UsagePool

    private var hasData: Bool { pool.pctUsed != nil }
    private var pct: Double { min(max(pool.pctUsed ?? 0, 0), 100) }
    private var level: UsageLevel { UsageLevel(pct: pool.pctUsed) }

    var body: some View {
        // The reset info brackets the bar: countdown beside the window name,
        // the actual reset time (local: "06:20", or "Sep 13 19:00" once it's
        // not today) right under it, opposite "% used".
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(pool.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetsAt = pool.resetsAt {
                    Text("Resets in \(ResetTimeFormatting.countdown(to: resetsAt))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Theme.color(for: level))
                    .frame(width: hasData ? Theme.barWidth * pct / 100 : 0)
            }
            .frame(width: Theme.barWidth, height: 4)

            HStack {
                Text(hasData ? "\(Int(pct))% used" : "no data")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetsAt = pool.resetsAt {
                    Text(ResetTimeFormatting.clock(resetsAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
