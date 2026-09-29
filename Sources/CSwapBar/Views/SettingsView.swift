import AppKit
import ProviderKit
import SwiftUI
import ZAIEngine

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case claude, antigravity, zai

    var id: String { rawValue }
    var kind: ProviderKind? {
        switch self {
        case .general: return nil
        case .claude: return .claude
        case .antigravity: return .antigravity
        case .zai: return .zai
        }
    }

    var title: String { kind?.title ?? "General" }
    var iconSource: ProviderIconSource { kind?.iconSource ?? .symbol("switch.2") }
}

struct SettingsView: View {
    @EnvironmentObject var store: ProviderStore
    @State private var page = SettingsPage.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            preview
            SettingsOptions(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            ForEach(SettingsPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    VStack(spacing: 3) {
                        ProviderIconView(source: item.iconSource, size: 19)
                            .frame(height: 24)
                        Text(item.title)
                            .font(.system(size: 10))
                    }
                    .frame(width: 74, height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(page == item ? (item.kind?.accent ?? Theme.accent) : Color.clear)
                    )
                    .foregroundStyle(selectedForeground(for: item))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// White on a dark accent (most providers), .primary otherwise -- a
    /// light accent (z.ai's) would render white-on-near-white when selected.
    private func selectedForeground(for item: SettingsPage) -> Color {
        guard page == item else { return .primary }
        let accent = item.kind?.accent ?? Theme.accent
        return accent.isLight ? .primary : .white
    }

    /// The real dropdown for this page, live.
    private var preview: some View {
        ScrollView {
            StatusBarController.dropdown(for: page.kind ?? .claude, store: store)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.vertical, 40)
                .padding(.horizontal, 24)
                .id(page)
        }
        .scrollIndicators(.never)
        .frame(width: Theme.panelWidth + 48)
        .background(
            LinearGradient(
                colors: [(page.kind?.accent ?? Theme.accent).opacity(0.55), Color.black.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

private struct SettingsOptions: View {
    @EnvironmentObject var store: ProviderStore
    let page: SettingsPage

    var body: some View {
        Form {
            switch page {
            case .general: GeneralSettings()
            case .claude: ClaudeSettings(provider: store.claude)
            case .antigravity: AntigravitySettings(provider: store.antigravity)
            case .zai: ZAISettings(provider: store.zai)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 28)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(ProviderSettings.orderKey) private var itemOrderRaw = ProviderSettings.encodeOrder(ProviderKind.allCases)
    @AppStorage(ProviderKind.claude.showDefaultsKey) private var showClaude = ProviderKind.claude.defaultEnabled
    @AppStorage(ProviderKind.antigravity.showDefaultsKey) private var showAntigravity = ProviderKind.antigravity.defaultEnabled
    @AppStorage(ProviderKind.zai.showDefaultsKey) private var showZai = ProviderKind.zai.defaultEnabled
    @State private var startsAtLogin = LoginItem.isEnabled

    var body: some View {
        Section {
            AboutHeader()
        }
        Section {
            ReorderList(order: order) { kind in
                HStack(spacing: 10) {
                    ProviderIconView(source: kind.iconSource, size: 14)
                        .frame(width: 18)
                        .foregroundStyle(kind.accent)
                    Text(kind.title)
                    Spacer()
                    Toggle(kind.title, isOn: shown(kind))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isLastShown(kind))
                }
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Drag ≡ to change the order. One item always stays in the menu bar so CSwapBar can be reached.")
                .foregroundStyle(.secondary)
        }
        Section("Behaviour") {
            Toggle("Start at login", isOn: $startsAtLogin)
                .onChange(of: startsAtLogin) { _, enabled in
                    LoginItem.setEnabled(enabled)
                    startsAtLogin = LoginItem.isEnabled
                }
        }
        Section {
            Button("Show Log File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.fileURL])
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Records connection errors for every provider -- attach this file when reporting a problem.")
                .foregroundStyle(.secondary)
        }
    }

    private var order: Binding<[ProviderKind]> {
        Binding {
            ProviderSettings.completeOrder(ProviderSettings.decodeOrder(itemOrderRaw))
        } set: {
            itemOrderRaw = ProviderSettings.encodeOrder($0)
        }
    }

    private func shown(_ kind: ProviderKind) -> Binding<Bool> {
        switch kind {
        case .claude: return $showClaude
        case .antigravity: return $showAntigravity
        case .zai: return $showZai
        }
    }

    private func isShown(_ kind: ProviderKind) -> Bool { shown(kind).wrappedValue }

    private func isLastShown(_ kind: ProviderKind) -> Bool {
        isShown(kind) && ProviderKind.allCases.filter(isShown).count == 1
    }
}

/// App icon, name, version and the update check.
private struct AboutHeader: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("CSwapBar")
                .font(.system(size: 17, weight: .semibold))
            if let version = Updater.currentVersion {
                Text("Version \(version)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Development build")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            HStack {
                updateControl
                Button("Quit CSwapBar") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var updateControl: some View {
        if let release = updater.availableUpdate {
            Button(updater.progressText ?? "Install v\(release.version)") {
                Task { await updater.update() }
            }
            .disabled(updater.isUpdating)
        } else if Updater.currentVersion != nil {
            Button(updater.isChecking ? "Checking…" : "Check for Updates") {
                Task { await updater.check() }
            }
            .disabled(updater.isChecking)
        }
    }
}

/// Rows reordered by dragging their ≡ handle. A hand-rolled gesture: the
/// pasteboard-based draggable/dropDestination doesn't deliver the drop
/// inside a grouped Form, so rows snap back.
private struct ReorderList<Row: View>: View {
    @Binding var order: [ProviderKind]
    @ViewBuilder var row: (ProviderKind) -> Row

    @State private var dragging: ProviderKind?
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            ForEach(order, id: \.self) { item in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(dragging == item ? .primary : .tertiary)
                        .frame(width: 22, height: rowHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                        .gesture(drag(item))
                    row(item)
                }
                .frame(height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(dragging == item ? Color.primary.opacity(0.08) : Color.clear)
                )
                .offset(y: dragging == item ? offset : shift(for: item))
                .zIndex(dragging == item ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: target)
    }

    private var target: Int? {
        guard let dragging, let from = order.firstIndex(of: dragging) else { return nil }
        return min(max(from + Int((offset / rowHeight).rounded()), 0), order.count - 1)
    }

    /// Rows between the dragged row's old and new place slide over to make room.
    private func shift(for item: ProviderKind) -> CGFloat {
        guard let dragging, let from = order.firstIndex(of: dragging), let to = target,
              let index = order.firstIndex(of: item) else { return 0 }
        if from < to, index > from, index <= to { return -rowHeight }
        if from > to, index >= to, index < from { return rowHeight }
        return 0
    }

    private func drag(_ item: ProviderKind) -> some Gesture {
        // Global coordinates: the row itself moves while being dragged.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                dragging = item
                offset = value.translation.height
            }
            .onEnded { _ in
                if let from = order.firstIndex(of: item), let to = target, from != to {
                    var reordered = order
                    reordered.remove(at: from)
                    reordered.insert(item, at: to)
                    order = reordered
                }
                dragging = nil
                offset = 0
            }
    }
}

// MARK: - Claude

private struct ClaudeSettings: View {
    @ObservedObject var provider: ClaudeProvider

    var body: some View {
        Section {
            Text("Claude").font(.title2.bold()).foregroundStyle(.primary)
        }
        Section("Accounts") {
            if provider.accounts.isEmpty {
                Text("No managed accounts yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.accounts) { account in
                    AccountManageRow(provider: provider, account: account)
                }
            }
        }
        Section {
            Button("Add current login") { Task { await provider.addFromCurrentLogin() } }
            Button("Add from setup-token…") { provider.openAddTokenWindow() }
            Button("Refresh current credentials") { Task { await provider.refreshCredentials() } }
        } header: {
            Text("Add")
        }
    }
}

// MARK: - z.ai

private struct ZAISettings: View {
    @ObservedObject var provider: ZAIProvider
    @State private var apiKey = ""
    @State private var region: ZAIRegion = .global
    @State private var status: String?

    var body: some View {
        Section {
            Text("z.ai").font(.title2.bold()).foregroundStyle(.primary)
            Text("GLM Coding Plan quota, from z.ai's own Settings → API keys page.")
                .foregroundStyle(.secondary)
        }
        Section("Account") {
            if provider.isConfigured {
                LabeledContent("Status", value: "API key configured")
                Button("Remove account", role: .destructive) {
                    provider.removeCredential()
                }
            } else {
                // A labeled TextField as a bare Section row can collapse its
                // editable area to nothing in this Form -- an explicit
                // caption + a separately-styled field is more reliable.
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", text: $apiKey) // plain, not SecureField -- see AddZAISheet for why
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Region", selection: $region) {
                    ForEach(ZAIRegion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Add account") {
                    Task {
                        await provider.setAPIKey(apiKey, region: region)
                        apiKey = ""
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Antigravity

private struct AntigravitySettings: View {
    @ObservedObject var provider: AntigravityProvider
    @State private var manualToken = ""
    @State private var showManualEntry = false

    var body: some View {
        Section {
            Text("Antigravity").font(.title2.bold()).foregroundStyle(.primary)
            Text("Gemini + Claude/GPT quota, auto-detected from the agy CLI's or the Antigravity IDE's own local login.")
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Right now", value: provider.isConfigured ? "Quota is reachable" : "No CLI session running, no fallback connected")
        } header: {
            Text("Status")
        } footer: {
            Text("Quota shows automatically whenever the agy CLI is running a session -- nothing to set up for that. A fallback account below fills in the gaps when no session is active.")
                .foregroundStyle(.secondary)
        }
        Section("Fallback account") {
            if let error = provider.errorMessage {
                Text(error).foregroundStyle(Theme.high)
            }
            if provider.hasStoredCredential {
                LabeledContent("Status", value: "Connected")
                Button(provider.isConnecting ? "Re-detecting…" : "Re-detect account") {
                    Task { await provider.autoDetect() }
                }
                .disabled(provider.isConnecting)
                Button("Remove account", role: .destructive) {
                    provider.removeCredential()
                }
            } else {
                Button(provider.isConnecting ? "Detecting…" : "Auto-detect from agy / Antigravity IDE") {
                    Task { await provider.autoDetect() }
                }
                .disabled(provider.isConnecting)
                Toggle("Paste a refresh token manually instead", isOn: $showManualEntry)
                if showManualEntry {
                    Text("The `refresh_token` value from `~/.gemini/jetski-standalone-oauth-token`'s `token` object.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    // A labeled TextField as a bare Section row can collapse
                    // its editable area to nothing in this Form -- an
                    // explicit caption + a separately-styled field is more
                    // reliable.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Refresh token").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("", text: $manualToken) // plain, not SecureField -- see AddZAISheet for why
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Connect") {
                        Task {
                            await provider.connectWithManualToken(manualToken)
                            manualToken = ""
                        }
                    }
                    .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty || provider.isConnecting)
                }
            }
        }
    }
}
