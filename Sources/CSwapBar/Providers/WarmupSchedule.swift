import Foundation
import ProviderKit

/// A provider that can send a throwaway message to start its usage window
/// counting -- by hand from the dropdown, or on a `WarmupSchedule`.
@MainActor
protocol WarmingUp: Provider {
    var isWarmingUp: Bool { get }
    var warmupStatusText: String? { get }
    func warmup() async
}

/// A time of day, entered and stored as 24-hour "HH:mm".
struct WarmupTime: Hashable, Comparable, Identifiable {
    let hour: Int
    let minute: Int

    var id: Int { hour * 60 + minute }
    var text: String { String(format: "%02d:%02d", hour, minute) }

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Accepts "5:00", "05:00" or "05.00"; nil for anything else.
    init?(_ raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    static func < (a: WarmupTime, b: WarmupTime) -> Bool { a.id < b.id }

    /// This time's occurrence on `day`'s calendar date.
    func occurrence(onDayOf day: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}

/// Per-provider scheduled warm-up times in UserDefaults, as a comma-joined
/// sorted list of "HH:mm" -- the same flat-string shape as the provider
/// order in `ProviderSettings`, so `@AppStorage` can bind it directly.
/// Switching the whole schedule or a single time off keeps it in the list:
/// the master switch is its own flag, and switched-off times are a second
/// list alongside the first.
enum WarmupSchedule {
    static func key(for kind: ProviderKind) -> String { "cswapbar.warmup.times.\(kind.rawValue)" }
    static func offKey(for kind: ProviderKind) -> String { "cswapbar.warmup.off.\(kind.rawValue)" }
    static func enabledKey(for kind: ProviderKind) -> String { "cswapbar.warmup.enabled.\(kind.rawValue)" }

    /// The times that should actually fire: none while the schedule is
    /// switched off, and never a time that's switched off on its own.
    static func activeTimes(for kind: ProviderKind) -> [WarmupTime] {
        let defaults = UserDefaults.standard
        return active(
            times: defaults.string(forKey: key(for: kind)) ?? "",
            off: defaults.string(forKey: offKey(for: kind)) ?? "",
            enabled: defaults.object(forKey: enabledKey(for: kind)) as? Bool ?? true
        )
    }

    static func active(times: String, off: String, enabled: Bool) -> [WarmupTime] {
        guard enabled else { return [] }
        let offTimes = Set(decode(off))
        return decode(times).filter { !offTimes.contains($0) }
    }

    static func decode(_ raw: String) -> [WarmupTime] {
        Array(Set(raw.split(separator: ",").compactMap { WarmupTime(String($0)) })).sorted()
    }

    static func encode(_ times: [WarmupTime]) -> String {
        Array(Set(times)).sorted().map(\.text).joined(separator: ",")
    }

    /// The next scheduled time after `now` (wrapping to tomorrow's first),
    /// for the dropdown's hint.
    static func next(in times: [WarmupTime], after now: Date = Date()) -> WarmupTime? {
        let calendar = Calendar.current
        let minuteOfDay = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return times.sorted().first { $0.id > minuteOfDay } ?? times.min()
    }
}

/// Fires each provider's warm-up at its scheduled times. Polls the wall
/// clock rather than arming timers, so a changed schedule, a clock change or
/// a sleep/wake needs no re-arming: every tick fires any scheduled time that
/// fell between the previous tick and now. A time missed by more than
/// `grace` (the Mac was asleep through it) is skipped rather than fired
/// late, since a warm-up hours off schedule shifts the window wrongly.
@MainActor
final class WarmupScheduler {
    private let providers: () -> [any WarmingUp]
    private let tick: TimeInterval = 20
    private let grace: TimeInterval = 15 * 60
    private var task: Task<Void, Never>?
    private var lastCheck = Date()

    init(providers: @escaping () -> [any WarmingUp]) {
        self.providers = providers
    }

    func start() {
        task?.cancel()
        lastCheck = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.tick ?? 20) * 1_000_000_000))
                self?.check()
            }
        }
    }

    private func check() {
        let now = Date()
        defer { lastCheck = now }
        guard now > lastCheck else { return } // the clock went backwards
        // A provider switched off in Settings is off entirely, schedule included.
        for provider in providers() where ProviderSettings.isShown(provider.kind) {
            let due = WarmupSchedule.activeTimes(for: provider.kind).contains { isDue($0, now: now) }
            guard due, !provider.isWarmingUp else { continue }
            DiagnosticLog.log(provider.kind.rawValue, "scheduled warm-up starting")
            Task { await provider.warmup() }
        }
    }

    /// Whether `time` occurred in (lastCheck, now] and at most `grace` ago --
    /// checking yesterday's occurrence too, for a tick that straddles midnight.
    private func isDue(_ time: WarmupTime, now: Date) -> Bool {
        let calendar = Calendar.current
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap { $0 }
        return days.contains { day in
            guard let at = time.occurrence(onDayOf: day, calendar: calendar) else { return false }
            return at > lastCheck && at <= now && now.timeIntervalSince(at) <= grace
        }
    }
}
