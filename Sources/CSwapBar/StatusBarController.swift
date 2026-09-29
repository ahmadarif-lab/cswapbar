import AppKit
import Combine
import SwiftUI

/// One status item per shown provider, each opening its own dropdown
/// anchored below it -- CodexBar/statbar-style.
///
/// The items are plain NSStatusItems rather than a SwiftUI MenuBarExtra:
/// MenuBarExtra's visibility binding is unreliable across dynamic show/hide
/// on recent macOS, and its buttons carry padding that can't be trimmed --
/// both matter once items can be toggled on/off from Settings.
///
/// macOS remembers where each status item sits, by name, and puts it back
/// there -- whatever order they're created in, and not always in the order
/// they were last left in once slots come and go. So the status items are
/// interchangeable slots: every refresh reads where each actually sits and
/// gives the leftmost the first provider in Settings order, and so on.
@MainActor
final class StatusBarController: NSObject {
    private let store: ProviderStore
    /// Interchangeable NSStatusItems, not yet tied to a provider.
    private var slots: [NSStatusItem] = []
    /// Slots as they sit in the menu bar, left to right; lines up with `slotKinds`.
    private var orderedSlots: [NSStatusItem] = []
    private var slotKinds: [ProviderKind] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openKind: ProviderKind?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on a status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open item would
    /// reopen it instead of toggling it shut.
    private var lastDismissal: (kind: ProviderKind, time: Date)?

    init(store: ProviderStore) {
        self.store = store
        super.init()
        store.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    private func refresh() {
        let kinds = ProviderSettings.shownKinds()
        // With every provider switched off, one slot stays as a plain
        // CSwapBar item (Settings/Quit only) so the app remains reachable.
        let slotCount = max(kinds.count, 1)
        if slotCount != slots.count { rebuildSlots(count: slotCount) }
        let positioned = slotsLeftToRight()
        if kinds != slotKinds || positioned != orderedSlots { close() }
        orderedSlots = positioned
        slotKinds = kinds

        if kinds.isEmpty, let button = orderedSlots.first?.button {
            let image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "CSwapBar")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.tag = 0
            button.setAccessibilityLabel("CSwapBar")
        }

        for (index, slot) in orderedSlots.enumerated() where index < slotKinds.count {
            let kind = slotKinds[index]
            let provider = store.provider(for: kind)
            let (top, bottom) = provider.accounts.menuBarPercentages()
            guard let button = slot.button else { continue }
            let style = MenuBarStyle.current
            // A balance-only provider (DeepSeek) has no bars to draw; its
            // remaining credit stands in for the percentage.
            let balance = provider.accounts.lazy.compactMap(\.balance).first
            let hasBars = balance == nil || top != nil || bottom != nil
            let text = style.showsText ? balance.map(\.total) ?? top.map { "\(Int($0))%" } : nil
            let showText = text != nil
            let showBars = style.showsBars && hasBars
            // Whatever the style, never leave a slot blank: fall back to the logo.
            let showIcon = style.showsIcon || (!showText && !showBars)
            button.image = MenuBarIcon.make(icon: showIcon ? kind.iconSource : nil, bars: showBars ? (top, bottom) : nil)
            button.title = text.map { " \($0)" } ?? ""
            button.tag = index
            button.setAccessibilityLabel("CSwapBar \(kind.title)")
        }
    }

    /// The slots in their on-screen order. Until macOS has placed them all
    /// (a zero-width window), creation order stands in.
    private func slotsLeftToRight() -> [NSStatusItem] {
        let frames = slots.map { $0.button?.window?.frame ?? .zero }
        guard frames.allSatisfy({ $0.width > 0 }) else { return slots }
        return slots.indices
            .sorted { (frames[$0].minX, $0) < (frames[$1].minX, $1) }
            .map { slots[$0] }
    }

    /// Recreates the slots when the number of shown providers changes. On
    /// first appearance macOS puts each new status item to the left of the
    /// existing ones, so they're created right to left.
    private func rebuildSlots(count: Int) {
        close()
        for slot in slots {
            NSStatusBar.system.removeStatusItem(slot)
        }
        var created: [NSStatusItem] = []
        for index in (0..<count).reversed() {
            let slot = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            slot.autosaveName = "CSwapBar.slot\(index)"
            slot.isVisible = true
            if let button = slot.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseDown, .rightMouseDown])
                button.imagePosition = .imageLeading
                button.font = .menuBarFont(ofSize: 11)
                button.tag = index
            }
            created.insert(slot, at: 0)
        }
        slots = created
        orderedSlots = []
        slotKinds = []
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        guard slotKinds.indices.contains(button.tag),
              event.type != .rightMouseDown, !event.modifierFlags.contains(.control) else {
            showContextMenu(from: button)
            return
        }
        let kind = slotKinds[button.tag]
        if openKind == kind {
            close()
            return
        }
        if let lastDismissal, lastDismissal.kind == kind, Date().timeIntervalSince(lastDismissal.time) < 0.3 {
            return
        }
        open(kind, from: button)
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        close()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CSwapBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    // MARK: - Dropdown

    private func open(_ kind: ProviderKind, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        let panel = DropdownPanel(
            content: Self.dropdown(for: kind, store: store),
            // Left edge lined up with the item, top a few points below the bar.
            anchor: NSPoint(x: window.frame.minX, y: window.frame.minY - 3),
            screen: window.screen
        )
        panel.onResignKey = { [weak self] in
            guard let self, self.openKind == kind else { return }
            self.close()
        }
        panel.onEscape = { [weak self] in self?.close() }
        panel.show()

        self.panel = panel
        openKind = kind
        button.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        if let openKind {
            lastDismissal = (openKind, Date())
            if let index = slotKinds.firstIndex(of: openKind), orderedSlots.indices.contains(index) {
                orderedSlots[index].button?.highlight(false)
            }
        }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel?.onResignKey = nil
        panel?.dismiss()
        panel = nil
        openKind = nil
    }

    static func dropdown(for kind: ProviderKind, store: ProviderStore) -> some View {
        Group {
            switch kind {
            case .claude:
                ProviderDropdownView(provider: store.claude) { ClaudeDropdownExtras(provider: store.claude) }
            case .antigravity:
                ProviderDropdownView(provider: store.antigravity) { AntigravityDropdownExtras(provider: store.antigravity) }
            case .zai:
                ProviderDropdownView(provider: store.zai) { ZAIDropdownExtras(provider: store.zai) }
            case .deepseek:
                ProviderDropdownView(provider: store.deepseek) { DeepSeekDropdownExtras(provider: store.deepseek) }
            }
        }
        .environmentObject(store.updater)
    }
}

/// Borderless panel hanging under the menu bar. It can take key status
/// (for Escape) without activating CSwapBar, so the app in front keeps focus.
final class DropdownPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?
    private let anchor: NSPoint
    private let visibleFrame: NSRect

    init<Content: View>(content: Content, anchor: NSPoint, screen: NSScreen?) {
        self.anchor = anchor
        visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        var resize: (CGSize) -> Void = { _ in }
        let hosting = NSHostingView(rootView:
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    DispatchQueue.main.async { resize(size) }
                }
        )
        contentView = hosting
        resize = { [weak self] size in self?.place(size) }
        place(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func show() {
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
        // Tear the SwiftUI tree down so the dropdown's onDisappear runs.
        contentView = nil
    }

    /// Top edge pinned under the menu bar, kept inside the screen.
    private func place(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = min(max(anchor.x, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4)
        setFrame(NSRect(x: x, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
