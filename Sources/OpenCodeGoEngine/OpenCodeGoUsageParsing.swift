import Foundation

/// Isolated from networking so it's unit-testable against captured JSON.
///
/// Neither payload is a published schema -- the API-key endpoint is
/// undocumented and has already changed shape once, and the console endpoint
/// is the console's own internal API -- so both are decoded defensively: a
/// window whose numbers are missing is dropped rather than failing the whole
/// report, and an unrecognized `status` reads as "ok" instead of a hard error.
enum OpenCodeGoUsageParsing {
    // MARK: - API-key endpoint (percents)

    static func summarize(_ response: OpenCodeGoUsageResponse, now: Date = Date()) throws -> OpenCodeGoUsageSummary {
        let windows = response.windows
        let parsed = OpenCodeGoWindow.Kind.allCases.compactMap { kind -> OpenCodeGoWindow? in
            guard let payload = windows.payload(for: kind) else { return nil }
            return parse(kind, payload, now: now)
        }
        guard !parsed.isEmpty else {
            throw OpenCodeGoEngineError.decoding("no usable usage windows in the response")
        }
        return OpenCodeGoUsageSummary(windows: parsed, planName: nil, renewsAt: nil)
    }

    private static func parse(_ kind: OpenCodeGoWindow.Kind, _ payload: OpenCodeGoWindowPayload, now: Date) -> OpenCodeGoWindow? {
        guard let raw = payload.percent, raw.isFinite else { return nil }
        return OpenCodeGoWindow(
            kind: kind,
            pctUsed: clampPercent(raw),
            resetsAt: resetDate(payload, now: now),
            isRateLimited: payload.status == "rate-limited",
            usedUSD: nil,
            limitUSD: nil
        )
    }

    private static func resetDate(_ payload: OpenCodeGoWindowPayload, now: Date) -> Date? {
        if let raw = payload.resetsAt, let date = date(fromISO: raw) { return date }
        if let seconds = payload.resetsInSeconds, seconds.isFinite { return now.addingTimeInterval(seconds) }
        return nil
    }

    // MARK: - Console endpoint (micro-cents)

    /// A payload with no `access` at all means the workspace has no Go
    /// subscription, which is worth its own error rather than a parse failure.
    static func summarizeConsole(_ status: OpenCodeGoConsoleStatus, now: Date = Date()) throws -> OpenCodeGoUsageSummary {
        guard let access = status.access, let meters = access.meters else {
            throw OpenCodeGoEngineError.noSubscription
        }
        let renewsAt = access.endsAt.flatMap(date(fromISO:))

        func window(_ kind: OpenCodeGoWindow.Kind, _ meter: OpenCodeGoConsoleStatus.Meter?, fallbackReset: Date?) -> OpenCodeGoWindow? {
            guard let meter else { return nil }
            let limit = meter.limitMicroCents?.value
            let used = meter.usedMicroCents?.value
            guard let limit, limit > 0, let used, used.isFinite else { return nil }
            let reset = meter.resetsAt.flatMap(date(fromISO:)) ?? fallbackReset
            return OpenCodeGoWindow(
                kind: kind,
                pctUsed: clampPercent(used / limit * 100),
                resetsAt: reset,
                isRateLimited: used >= limit,
                usedUSD: meter.usedMicroCents?.usd,
                limitUSD: meter.limitMicroCents?.usd
            )
        }

        let parsed = [
            // The month meter carries no reset of its own; the billing
            // period's end is the monthly reset.
            window(.rolling, meters.fiveHour, fallbackReset: nil),
            window(.weekly, meters.week, fallbackReset: nil),
            window(.monthly, meters.month, fallbackReset: renewsAt),
        ].compactMap { $0 }

        guard !parsed.isEmpty else {
            throw OpenCodeGoEngineError.decoding("the console reported no usable usage meters")
        }
        return OpenCodeGoUsageSummary(
            windows: parsed,
            planName: planName(status.product ?? status.renewalProduct),
            renewsAt: renewsAt
        )
    }

    private static func planName(_ product: String?) -> String? {
        guard let product = product?.trimmingCharacters(in: .whitespaces), !product.isEmpty else { return nil }
        let lower = product.lowercased()
        if lower.contains("plus") { return "Go Plus" }
        if lower == "go" { return "Go" }
        return product.prefix(1).uppercased() + product.dropFirst()
    }

    // MARK: - Shared

    /// A percent outside 0-100 would break the bar's own geometry; clamp
    /// rather than discard, so the window still shows up.
    private static func clampPercent(_ raw: Double) -> Double {
        min(max(raw, 0), 100)
    }

    /// The server sends fractional seconds (`…T16:27:38.287Z`); the plain
    /// form is accepted too, in case that ever changes.
    private static func date(fromISO raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
