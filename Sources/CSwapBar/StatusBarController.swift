import AppKit
import Combine
import SwiftUI

/// The menu bar items, each provider opening its own dropdown anchored
/// below it -- CodexBar/statbar-style.
///
/// The items are plain NSStatusItems rather than a SwiftUI MenuBarExtra:
/// MenuBarExtra's visibility binding is unreliable across dynamic show/hide
/// on recent macOS, and its buttons carry padding that can't be trimmed.
///
/// Grouped (the default), every provider is drawn side by side in one
/// status item: macOS places each status item on its own, so separate items
/// drift apart and other apps' items end up wedged between them. A click is
/// mapped back to the provider under it. Ungrouped, each provider gets its
/// own status item.
///
/// macOS remembers where each status item sits, by name, and puts it back
/// there -- whatever order they're created in, and not always in the order
/// they were last left in once items come and go. So ungrouped items are
/// interchangeable slots: every refresh reads where each actually sits and
/// gives the leftmost the first provider in Settings order, and so on.
@MainActor
final class StatusBarController: NSObject {
    private let store: ProviderStore
    /// Interchangeable NSStatusItems, not yet tied to a provider.
    private var slots: [NSStatusItem] = []
    /// Whether `slots` were built as one grouped item.
    private var slotsGrouped = false
    /// Slots as they sit in the menu bar, left to right; lines up with
    /// `slotKinds` and `slotSpans`.
    private var orderedSlots: [NSStatusItem] = []
    /// The providers each slot draws, left to right.
    private var slotKinds: [[ProviderKind]] = []
    /// Each provider's horizontal extent within its slot's image.
    private var slotSpans: [[ClosedRange<CGFloat>]] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openKind: ProviderKind?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on a status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open provider
    /// would reopen it instead of toggling it shut.
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
        let style = MenuBarStyle.current
        let shown = ProviderSettings.shownKinds()
        // With every provider switched off, one slot stays as a plain
        // CSwapBar item (Settings/Quit only) so the app remains reachable.
        let groups: [[ProviderKind]] = shown.isEmpty ? [[]] : style.groupsItems ? [shown] : shown.map { [$0] }
        if groups.count != slots.count || style.groupsItems != slotsGrouped {
            rebuildSlots(count: groups.count, grouped: style.groupsItems)
        }
        let positioned = slotsLeftToRight()
        if groups != slotKinds || positioned != orderedSlots { close() }
        orderedSlots = positioned
        slotKinds = groups
        slotSpans = []

        for (slot, kinds) in zip(orderedSlots, groups) {
            guard let button = slot.button else {
                slotSpans.append([])
                continue
            }
            if kinds.isEmpty {
                let image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "CSwapBar")
                image?.isTemplate = true
                button.image = image
                button.setAccessibilityLabel("CSwapBar")
                slotSpans.append([])
                continue
            }
            let (image, spans) = MenuBarIcon.make(kinds.map { segment(for: $0, style: style) })
            button.image = image
            slotSpans.append(spans)
            button.setAccessibilityLabel("CSwapBar " + kinds.map(\.title).joined(separator: ", "))
        }
    }

    private func segment(for kind: ProviderKind, style: MenuBarStyle) -> MenuBarIcon.Segment {
        let provider = store.provider(for: kind)
        let (top, bottom) = provider.accounts.menuBarPercentages()
        // A balance-only provider (DeepSeek) has no bars or percentage;
        // it shows its remaining credit under its own switch instead.
        let balance = provider.accounts.lazy.compactMap(\.balance).first
        let hasBars = balance == nil || top != nil || bottom != nil
        // Kiro picks bar or percentage for itself, overriding the global
        // switches (its one window would otherwise show the same number twice).
        let kiroDisplay = kind == .kiro ? KiroMenuBarDisplay.current : nil
        let wantsBars = kiroDisplay.map { $0 == .bar } ?? style.showsBars
        let wantsText = kiroDisplay.map { $0 == .percentage } ?? style.showsText
        let text = if let balance {
            style.showsBalance ? balance.total : nil
        } else {
            wantsText ? top.map { "\(Int($0))%" } : nil
        }
        let showBars = wantsBars && hasBars
        // Whatever the style, never leave a segment blank: fall back to the logo.
        let showIcon = style.showsIcon || (text == nil && !showBars)
        return MenuBarIcon.Segment(
            icon: showIcon ? kind.iconSource : nil,
            bars: showBars ? (top, bottom) : nil,
            text: text
        )
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

    /// Recreates the slots when their number or the grouping changes. On
    /// first appearance macOS puts each new status item to the left of the
    /// existing ones, so they're created right to left. The grouped item
    /// reuses the first slot's name, so it keeps where the user last put it.
    private func rebuildSlots(count: Int, grouped: Bool) {
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
                button.imagePosition = .imageOnly
            }
            created.insert(slot, at: 0)
        }
        slots = created
        slotsGrouped = grouped
        orderedSlots = []
        slotKinds = []
        slotSpans = []
    }

    /// Where the image starts inside the button; the button centers it.
    private func imageOffset(in button: NSStatusBarButton) -> CGFloat {
        ((button.bounds.width - (button.image?.size.width ?? 0)) / 2).rounded(.down)
    }

    /// The provider under a click, snapping to the nearest segment when the
    /// click lands in the gap between two (or the button's padding).
    private func kindIndex(at x: CGFloat, in spans: [ClosedRange<CGFloat>]) -> Int? {
        guard !spans.isEmpty else { return nil }
        func distance(_ span: ClosedRange<CGFloat>) -> CGFloat {
            span.contains(x) ? 0 : min(abs(x - span.lowerBound), abs(x - span.upperBound))
        }
        return spans.indices.min { distance(spans[$0]) < distance(spans[$1]) }
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent,
              let slot = orderedSlots.firstIndex(where: { $0.button === button }),
              slotKinds.indices.contains(slot), slotSpans.indices.contains(slot) else { return }
        let kinds = slotKinds[slot]
        let spans = slotSpans[slot]
        // The event's own location is the button's center, not where the
        // click landed, so read the cursor itself.
        let x = NSEvent.mouseLocation.x - (button.window?.frame.minX ?? 0) - imageOffset(in: button)
        guard let index = kindIndex(at: x, in: spans), kinds.indices.contains(index),
              event.type != .rightMouseDown, !event.modifierFlags.contains(.control) else {
            showContextMenu(from: button)
            return
        }
        let kind = kinds[index]
        if openKind == kind {
            close()
            return
        }
        if let lastDismissal, lastDismissal.kind == kind, Date().timeIntervalSince(lastDismissal.time) < 0.3 {
            return
        }
        open(kind, at: spans[index].lowerBound, from: button)
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

    /// `segmentX` is where the provider's segment starts in the button's image.
    private func open(_ kind: ProviderKind, at segmentX: CGFloat, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        // Left edge lined up with the provider's segment (the item's own
        // edge for the first one), top a few points below the bar.
        let anchorX = segmentX > 0 ? window.frame.minX + imageOffset(in: button) + segmentX : window.frame.minX
        let panel = DropdownPanel(
            content: Self.dropdown(for: kind, store: store),
            anchor: NSPoint(x: anchorX, y: window.frame.minY - 3),
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
            for slot in slots { slot.button?.highlight(false) }
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
            case .opencodeGo:
                ProviderDropdownView(provider: store.opencodeGo) { OpenCodeGoDropdownExtras(provider: store.opencodeGo) }
            case .kiro:
                ProviderDropdownView(provider: store.kiro) { KiroDropdownExtras(provider: store.kiro) }
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
