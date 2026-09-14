import Foundation

/// The account operations the app offers, run natively against claude-swap's
/// own data (`~/.claude-swap-backup`, the `claude-swap` Keychain items and
/// Claude Code's live login). Operations run one at a time on a background
/// queue, each on a fresh engine — the same isolation one `cswap` process
/// per action used to give.
public final class AccountEngine: @unchecked Sendable {
    public static let shared = AccountEngine()

    /// The claude-swap release this engine was ported from.
    public static let upstreamVersion = "0.26.0"

    private let queue = DispatchQueue(label: "cswapbar.account-engine", qos: .userInitiated)
    private let makeEnvironment: () -> EngineEnvironment

    public convenience init() {
        self.init(environment: EngineEnvironment.live)
    }

    init(environment: @escaping () -> EngineEnvironment) {
        makeEnvironment = environment
    }

    private func run<T>(_ body: @escaping (Switcher) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [makeEnvironment] in
                continuation.resume(with: Result { try body(Switcher(env: makeEnvironment())) })
            }
        }
    }

    public func list() async throws -> ListResponse {
        try await run { try $0.listAccounts() }
    }

    public func switchTo(_ number: Int) async throws {
        try await run { try $0.switchTo(String(number)) }
    }

    public func disable(_ number: Int) async throws {
        try await run { try $0.setAccountDisabled(String(number), true) }
    }

    public func enable(_ number: Int) async throws {
        try await run { try $0.setAccountDisabled(String(number), false) }
    }

    public func remove(_ number: Int) async throws {
        try await run { try $0.removeAccount(String(number)) }
    }

    /// Doubles as "refresh credentials" when the current login is already
    /// managed.
    public func addCurrentLogin() async throws {
        try await run { try $0.addAccount() }
    }

    public func addToken(_ token: String, email: String?) async throws {
        try await run { try $0.addAccountFromToken(token, email: email) }
    }
}
