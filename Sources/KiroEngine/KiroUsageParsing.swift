import Foundation

/// Parses the plain-text usage report `kiro-cli chat --no-interactive
/// "/usage"` prints:
///
/// ```
/// Estimated Usage | resets on 2026-11-01 | KIRO PRO
/// Credits (160.89 of 1000 covered in plan), 16.1%
/// Your plan is managed by your organization's administrator.
/// ```
///
/// Kiro publishes no usage API to call instead, so this report is the only
/// source there is -- and it's the CLI's own rendering, not a schema. Every
/// part of it is therefore read leniently: the plan name, the reset date and
/// the per-unit amounts are all optional, and each is dropped on its own if
/// its wording ever changes. Only a report with no percentage at all fails,
/// since a bar drawn from a guessed 0% would be worse than an error.
enum KiroUsageParsing {
    static func summarize(_ text: String) throws -> KiroUsageSummary {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // The header is the one line made of `|`-separated fields; the title
        // comes first, so the plan is whatever field follows it that isn't
        // the reset.
        let fields = (lines.first { $0.contains("|") } ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let planName = fields
            .dropFirst()
            .last { !$0.isEmpty && !isResetField($0) }
        let resetsAt = fields.first(where: isResetField).flatMap(resetDate)

        // "Credits (…)" is the only line that spells out the amounts.
        let spelled = lines.lazy.compactMap(amounts(in:)).first
        let percent = spelled?.percent ?? lines.lazy.compactMap(percentValue(in:)).first
        guard let pctUsed = percent else {
            throw KiroEngineError.decoding("the report had no usage percentage: \(snippet(text))")
        }

        return KiroUsageSummary(
            planName: planName,
            pctUsed: min(max(pctUsed, 0), 100),
            unit: spelled?.unit,
            used: spelled?.used,
            limit: spelled?.limit,
            resetsAt: resetsAt
        )
    }

    private static func isResetField(_ field: String) -> Bool {
        field.lowercased().contains("resets on")
    }

    /// "2026-11-01" out of "resets on 2026-11-01".
    private static func resetDate(from field: String) -> Date? {
        guard let range = field.range(of: "resets on", options: .caseInsensitive) else { return nil }
        let raw = field[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    /// "Credits (160.89 of 1000 covered in plan), 16.1%" -> (Credits, 160.89,
    /// 1000, 16.1). A line without the parenthesised amounts yields nil, so
    /// the caller falls back to a bare percentage.
    private static func amounts(in line: String) -> (unit: String?, used: Double?, limit: Double?, percent: Double?)? {
        guard line.lowercased().contains("covered in plan"),
              let open = line.firstIndex(of: "("),
              let close = line.firstIndex(of: ")"), open < close else { return nil }

        let unit = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let inside = line[line.index(after: open)..<close].split(separator: " ").map(String.init)
        guard let ofIndex = inside.firstIndex(of: "of"), ofIndex > 0, ofIndex + 1 < inside.count else { return nil }

        return (
            unit: unit.isEmpty ? nil : unit,
            used: number(inside[ofIndex - 1]),
            limit: number(inside[ofIndex + 1]),
            percent: percentValue(in: String(line[line.index(after: close)...]))
        )
    }

    /// Wherever a "…%" sits in the text, its value. Walks back from the sign
    /// so "16.1%" and "1,000%" both read.
    private static func percentValue(in text: String) -> Double? {
        guard let sign = text.firstIndex(of: "%") else { return nil }
        var digits = ""
        var index = sign
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            guard character.isNumber || character == "." else { break }
            digits.insert(character, at: digits.startIndex)
            index = previous
        }
        return Double(digits)
    }

    /// Thousands separators ride along in the report's own numbers.
    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func snippet(_ text: String) -> String {
        let flattened = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return String(flattened.prefix(200))
    }
}
