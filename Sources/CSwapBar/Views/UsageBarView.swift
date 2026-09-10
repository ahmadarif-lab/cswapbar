import SwiftUI

/// Thin, fixed-width capsule bar (CodexBar-style). Deliberately not a
/// ProgressView/GeometryReader-based bar: both render taller/thicker than
/// intended here, and GeometryReader specifically breaks layout when this
/// view sits inside certain MenuBarExtra(.window) container hierarchies.
struct UsageBarView: View {
    let label: String
    let window: UsageWindow?

    private var hasData: Bool { window?.pct != nil }
    private var pct: Double { min(max(window?.pct ?? 0, 0), 100) }
    private var level: UsageLevel { UsageLevel(pct: window?.pct) }

    var body: some View {
        // The reset info brackets the bar: countdown beside the window name,
        // the actual reset time (local, formatted by cswap: "06:20", or
        // "Sep 13 19:00" for 7d) right under it, opposite "% used".
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let countdown = window?.countdown {
                    Text("Resets in \(countdown)")
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
                if let clock = window?.clock {
                    Text(clock)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
