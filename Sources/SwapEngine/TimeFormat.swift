import Foundation

/// Date/time helpers matching the Python stdlib behaviour cswap relies on.
enum TimeFormat {
    /// `models.get_timestamp`: current UTC time as `2026-09-14T06:33:55Z`.
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// `datetime.fromtimestamp(ts, tz=utc).isoformat(timespec="seconds")`
    /// with `+00:00` rewritten to `Z`.
    static func isoSecondsZ(_ epoch: Double) -> String {
        timestamp(Date(timeIntervalSince1970: floor(epoch)))
    }

    /// `datetime.fromisoformat(s)`: `YYYY-MM-DD[T| ]HH:MM[:SS[.ffffff]][Z|±HH:MM[:SS]]`.
    /// A value without an offset is naive and, like Python's `.timestamp()`,
    /// read as local time.
    static func parseISO(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2})(?::(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?)?(Z|[+-]\d{2}(?::?\d{2}(?::?\d{2}(?:\.\d+)?)?)?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
            return String(s[range])
        }
        var comps = DateComponents()
        comps.year = Int(group(1)!)
        comps.month = Int(group(2)!)
        comps.day = Int(group(3)!)
        comps.hour = group(4).flatMap(Int.init) ?? 0
        comps.minute = group(5).flatMap(Int.init) ?? 0
        comps.second = group(6).flatMap(Int.init) ?? 0
        var fraction = 0.0
        if let frac = group(7) { fraction = Double("0." + frac) ?? 0 }

        var tz = TimeZone.current
        if let offset = group(8) {
            if offset == "Z" {
                tz = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = offset.hasPrefix("-") ? -1 : 1
                let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
                let hh = Int(digits.prefix(2)) ?? 0
                let mm = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
                let ss = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 0 : 0
                guard let zone = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60 + ss)) else { return nil }
                tz = zone
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let date = cal.date(from: comps) else { return nil }
        let check = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard check.year == comps.year, check.month == comps.month, check.day == comps.day else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// `oauth.format_reset`: `(countdown, clock)` for a reset time, local.
    static func formatReset(_ resetsAt: String, now: Date) -> (countdown: String, clock: String)? {
        guard let reset = parseISO(resetsAt) else { return nil }
        let remaining = reset.timeIntervalSince(now)
        let total = max(0, Int(remaining.rounded(.towardZero)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let countdown: String
        if days > 0 {
            countdown = "\(days)d \(hours)h"
        } else if hours > 0 {
            countdown = "\(hours)h \(minutes)m"
        } else {
            countdown = "\(minutes)m"
        }
        return (countdown, resetClockString(reset, now: now))
    }

    /// `oauth.reset_clock_string`: "20:39" same-day, else "Jul 5 08:59".
    static func resetClockString(_ reset: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        if cal.isDate(reset, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
            return f.string(from: reset)
        }
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: reset)
    }

    /// `logging.Formatter` asctime: `2026-09-14 13:22:31,993`, local time.
    static func logTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return f.string(from: date)
    }
}
