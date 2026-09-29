import Foundation

/// UserDefaults-backed, non-secret settings: which providers show a menu bar
/// item and in what order. Modeled on statbar's `Settings.swift` -- order is
/// a comma-joined string of raw values, decoding drops names it doesn't
/// recognize and appends any case missing from a stored order at the end,
/// so a future provider slots in without a migration.
enum ProviderSettings {
    static let orderKey = "cswapbar.provider.order"

    static func registerDefaults() {
        var defaults: [String: Any] = [
            orderKey: encodeOrder(ProviderKind.allCases),
            MenuBarStyle.iconKey: false,
            MenuBarStyle.barsKey: true,
            MenuBarStyle.textKey: true,
            MenuBarStyle.balanceKey: true,
        ]
        for kind in ProviderKind.allCases {
            defaults[kind.showDefaultsKey] = kind.defaultEnabled
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isShown(_ kind: ProviderKind) -> Bool {
        UserDefaults.standard.bool(forKey: kind.showDefaultsKey)
    }

    static func setShown(_ kind: ProviderKind, _ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: kind.showDefaultsKey)
    }

    /// Every provider, in display order (order preference first, then any
    /// case missing from it).
    static func orderedKinds() -> [ProviderKind] {
        completeOrder(decodeOrder(UserDefaults.standard.string(forKey: orderKey) ?? ""))
    }

    static func setOrder(_ kinds: [ProviderKind]) {
        UserDefaults.standard.set(encodeOrder(kinds), forKey: orderKey)
    }

    /// Providers currently shown, in display order.
    static func shownKinds() -> [ProviderKind] {
        orderedKinds().filter(isShown)
    }

    /// Fills in any case missing from a stored order, at the end -- so a
    /// future provider slots in without a migration.
    static func completeOrder(_ stored: [ProviderKind]) -> [ProviderKind] {
        var seen = Set(stored)
        var result = stored
        for kind in ProviderKind.allCases where !seen.contains(kind) {
            result.append(kind)
            seen.insert(kind)
        }
        return result
    }

    static func decodeOrder(_ raw: String) -> [ProviderKind] {
        raw.split(separator: ",").compactMap { ProviderKind(rawValue: String($0)) }
    }

    static func encodeOrder(_ kinds: [ProviderKind]) -> String {
        kinds.map(\.rawValue).joined(separator: ",")
    }
}

/// What every provider's menu bar item shows: its logo, its usage bars,
/// its percentage, and (for a balance-only provider like DeepSeek) its
/// balance -- any combination. Balance is its own switch rather than riding
/// on the percentage, so e.g. Claude can show icon + bars while DeepSeek
/// shows icon + balance. The defaults (bars + percentage + balance) are the
/// original look.
struct MenuBarStyle {
    static let iconKey = "cswapbar.menubar.icon"
    static let barsKey = "cswapbar.menubar.bars"
    static let textKey = "cswapbar.menubar.text"
    static let balanceKey = "cswapbar.menubar.balance"

    let showsIcon: Bool
    let showsBars: Bool
    let showsText: Bool
    let showsBalance: Bool

    static var current: MenuBarStyle {
        let defaults = UserDefaults.standard
        return MenuBarStyle(
            showsIcon: defaults.bool(forKey: iconKey),
            showsBars: defaults.bool(forKey: barsKey),
            showsText: defaults.bool(forKey: textKey),
            showsBalance: defaults.bool(forKey: balanceKey)
        )
    }
}
