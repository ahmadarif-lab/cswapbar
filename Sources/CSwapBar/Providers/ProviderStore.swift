import Combine
import Foundation

/// Owns one instance per provider and republishes their changes, so a single
/// `@StateObject`/`@EnvironmentObject` drives the whole multi-provider UI.
/// Successor to the old single-provider `AppState`.
@MainActor
final class ProviderStore: ObservableObject {
    let claude = ClaudeProvider()
    let zai = ZAIProvider()
    let antigravity = AntigravityProvider()
    let updater = Updater()

    private var cancellables: Set<AnyCancellable> = []
    private var lastAppliedShownKinds: Set<ProviderKind>?

    init() {
        Publishers.MergeMany(
            claude.objectWillChange.eraseToAnyPublisher(),
            zai.objectWillChange.eraseToAnyPublisher(),
            antigravity.objectWillChange.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &cancellables)

        // Settings can flip a provider's menu bar toggle at any time; keep
        // each provider's own poll loop in sync without restarting the ones
        // that didn't actually change.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyEnabledProvidersFromSettings() }
            .store(in: &cancellables)
    }

    func provider(for kind: ProviderKind) -> any Provider {
        switch kind {
        case .claude: return claude
        case .antigravity: return antigravity
        case .zai: return zai
        }
    }

    /// Starts/stops each provider's own poll loop to match its current
    /// Settings toggle -- called at launch and whenever a toggle changes.
    /// A no-op when the shown set hasn't actually changed, so unrelated
    /// UserDefaults writes don't restart every provider's poll loop.
    func applyEnabledProvidersFromSettings() {
        let shown = Set(ProviderSettings.shownKinds())
        guard shown != lastAppliedShownKinds else { return }
        lastAppliedShownKinds = shown
        for kind in ProviderKind.allCases {
            let provider = provider(for: kind)
            if shown.contains(kind) {
                provider.startAutoRefresh(interval: kind == .antigravity ? 60 : 30)
            } else {
                provider.stopAutoRefresh()
            }
        }
    }
}
