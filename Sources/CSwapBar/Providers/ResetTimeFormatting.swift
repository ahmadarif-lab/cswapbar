import Foundation

/// Client-side counterpart of `SwapEngine`'s `TimeFormat.formatReset` /
/// `resetClockString`, operating on a plain `Date` so it applies uniformly
/// to every provider's `UsagePool.resetsAt` instead of only Claude's
/// pre-baked, server-formatted strings.
enum ResetTimeFormatting {
    /// "2d 4h" / "3h 12m" / "45m".
    static func countdown(to reset: Date, from now: Date = Date()) -> String {
        let total = max(0, Int(reset.timeIntervalSince(now).rounded(.towardZero)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "20:39" same-day, else "Jul 5 08:59", both local.
    static func clock(_ reset: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if calendar.isDate(reset, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MMM d HH:mm"
        }
        return formatter.string(from: reset)
    }
}
