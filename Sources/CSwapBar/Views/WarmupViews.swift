import SwiftUI

/// The dropdown's "Warm-up" section: a run-now row, with the next scheduled
/// time (if any) at its trailing edge.
struct WarmupDropdownSection<P: WarmingUp>: View {
    @ObservedObject var provider: P
    var title = "Warm up now"
    /// Overrides the provider's own status line (Claude adds progress).
    var subtitle: String?
    var disabled = false

    @AppStorage private var timesRaw: String
    @AppStorage private var offRaw: String
    @AppStorage private var enabled: Bool

    init(provider: P, title: String = "Warm up now", subtitle: String? = nil, disabled: Bool = false) {
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.disabled = disabled
        _timesRaw = AppStorage(wrappedValue: "", WarmupSchedule.key(for: provider.kind))
        _offRaw = AppStorage(wrappedValue: "", WarmupSchedule.offKey(for: provider.kind))
        _enabled = AppStorage(wrappedValue: true, WarmupSchedule.enabledKey(for: provider.kind))
    }

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Warm-up")
        ActionRow(
            icon: "flame",
            title: provider.isWarmingUp ? "Warming up…" : title,
            subtitle: subtitle ?? provider.warmupStatusText,
            detail: nextText,
            tint: Theme.accent,
            disabled: provider.isWarmingUp || disabled
        ) {
            Task { await provider.warmup() }
        }
    }

    private var nextText: String? {
        let active = WarmupSchedule.active(times: timesRaw, off: offRaw, enabled: enabled)
        return WarmupSchedule.next(in: active).map { "Next \($0.text)" }
    }
}

/// Settings editor for one provider's scheduled warm-up times: the
/// scheduled list plus a native hour:minute picker to add another -- a
/// picker rather than a text field, so an invalid time can't be entered.
struct WarmupScheduleSection: View {
    let kind: ProviderKind
    let explanation: String

    @AppStorage private var timesRaw: String
    @AppStorage private var offRaw: String
    @AppStorage private var enabled: Bool
    @State private var draft = Calendar.current.date(bySettingHour: 5, minute: 0, second: 0, of: Date()) ?? Date()

    init(kind: ProviderKind, explanation: String) {
        self.kind = kind
        self.explanation = explanation
        _timesRaw = AppStorage(wrappedValue: "", WarmupSchedule.key(for: kind))
        _offRaw = AppStorage(wrappedValue: "", WarmupSchedule.offKey(for: kind))
        _enabled = AppStorage(wrappedValue: true, WarmupSchedule.enabledKey(for: kind))
    }

    var body: some View {
        Section {
            Toggle("Run scheduled warm-ups", isOn: $enabled)
                .toggleStyle(.switch)
            if times.isEmpty {
                Text("No times scheduled yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(times) { time in
                let isOn = enabled && !offTimes.contains(time)
                HStack(spacing: 10) {
                    Image(systemName: "alarm")
                        .foregroundStyle(isOn ? kind.accent : .secondary)
                        .frame(width: 18)
                    Text(time.text)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(isOn ? .primary : .secondary)
                    Text(isOn ? countdown(to: time) : "Off")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: timeEnabled(time))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!enabled)
                        .help(offTimes.contains(time) ? "Turn \(time.text) on" : "Turn \(time.text) off")
                    Button {
                        timesRaw = WarmupSchedule.encode(times.filter { $0 != time })
                        offRaw = WarmupSchedule.encode(offTimes.filter { $0 != time })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(time.text)")
                }
            }
            HStack(spacing: 10) {
                DatePicker("Time", selection: $draft, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    // en_GB renders 24-hour HH:mm regardless of the
                    // system's 12/24-hour preference.
                    .environment(\.locale, Locale(identifier: "en_GB"))
                Button {
                    add()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(isDuplicate)
                if isDuplicate {
                    Text("Already scheduled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            SectionTitle("Scheduled warm-up", help: "\(explanation) Runs only while CSwapBar is open; a time missed by more than 15 minutes (e.g. the Mac was asleep) is skipped.")
        }
    }

    private var times: [WarmupTime] { WarmupSchedule.decode(timesRaw) }
    private var offTimes: [WarmupTime] { WarmupSchedule.decode(offRaw) }

    private func timeEnabled(_ time: WarmupTime) -> Binding<Bool> {
        Binding {
            !offTimes.contains(time)
        } set: { on in
            let others = offTimes.filter { $0 != time }
            offRaw = WarmupSchedule.encode(on ? others : others + [time])
        }
    }

    private var draftTime: WarmupTime {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: draft)
        return WarmupTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    private var isDuplicate: Bool { times.contains(draftTime) }

    private func add() {
        guard !isDuplicate else { return }
        timesRaw = WarmupSchedule.encode(times + [draftTime])
    }

    /// "in 3h 12m" until the time's next occurrence.
    private func countdown(to time: WarmupTime) -> String {
        let now = Date()
        let minuteOfDay = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        var minutes = time.id - minuteOfDay
        if minutes <= 0 { minutes += 24 * 60 }
        let hours = minutes / 60
        return hours > 0 ? "in \(hours)h \(minutes % 60)m" : "in \(minutes)m"
    }
}
