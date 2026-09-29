import AppKit
import Combine
import SwiftUI

/// A single status item showing every shown provider side by side, each
/// segment opening its own dropdown anchored below it.
///
/// It's a plain NSStatusItem rather than a SwiftUI MenuBarExtra:
/// MenuBarExtra's visibility binding is unreliable across dynamic show/hide
/// on recent macOS, and its buttons carry padding that can't be trimmed.
///
/// One item rather than one per provider: macOS places each status item on
/// its own, so separate items drift apart and other apps' items end up
/// wedged between them. Drawn as one strip, the providers always stay
/// together, in Settings order; a click is mapped back to its segment.
@MainActor
final class StatusBarController: NSObject {
    private let store: ProviderStore
    private let item: NSStatusItem
    /// The providers drawn, left to right; lines up with `spans`.
    private var kinds: [ProviderKind] = []
    /// Each provider's horizontal extent within the item's image.
    private var spans: [ClosedRange<CGFloat>] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openKind: ProviderKind?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on the status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open segment
    /// would reopen it instead of toggling it shut.
    private var lastDismissal: (kind: ProviderKind, time: Date)?

    init(store: ProviderStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Reuses the first per-provider slot's name so the item keeps where
        // the user last put it.
        item.autosaveName = "CSwapBar.slot0"
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
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
        guard let button = item.button else { return }
        let shown = ProviderSettings.shownKinds()
        if shown != kinds { close() }
        kinds = shown

        // With every provider switched off, a plain CSwapBar icon stays
        // (Settings/Quit only) so the app remains reachable.
        if shown.isEmpty {
            let image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "CSwapBar")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("CSwapBar")
            spans = []
            return
        }

        let style = MenuBarStyle.current
        let segments = shown.map { kind -> MenuBarIcon.Segment in
            let provider = store.provider(for: kind)
            let (top, bottom) = provider.accounts.menuBarPercentages()
            // A balance-only provider (DeepSeek) has no bars or percentage;
            // it shows its remaining credit under its own switch instead.
            let balance = provider.accounts.lazy.compactMap(\.balance).first
            let hasBars = balance == nil || top != nil || bottom != nil
            let text = if let balance {
                style.showsBalance ? balance.total : nil
            } else {
                style.showsText ? top.map { "\(Int($0))%" } : nil
            }
            let showBars = style.showsBars && hasBars
            // Whatever the style, never leave a segment blank: fall back to the logo.
            let showIcon = style.showsIcon || (text == nil && !showBars)
            return MenuBarIcon.Segment(
                icon: showIcon ? kind.iconSource : nil,
                bars: showBars ? (top, bottom) : nil,
                text: text
            )
        }
        let (image, spans) = MenuBarIcon.make(segments)
        button.image = image
        self.spans = spans
        button.setAccessibilityLabel("CSwapBar " + shown.map(\.title).joined(separator: ", "))
    }

    /// Where the image starts inside the button; the button centers it.
    private func imageOffset(in button: NSStatusBarButton) -> CGFloat {
        ((button.bounds.width - (button.image?.size.width ?? 0)) / 2).rounded(.down)
    }

    /// The provider under a click, snapping to the nearest segment when the
    /// click lands in the gap between two (or the button's padding).
    private func kindIndex(at x: CGFloat) -> Int? {
        guard !spans.isEmpty else { return nil }
        func distance(_ span: ClosedRange<CGFloat>) -> CGFloat {
            span.contains(x) ? 0 : min(abs(x - span.lowerBound), abs(x - span.upperBound))
        }
        return spans.indices.min { distance(spans[$0]) < distance(spans[$1]) }
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // The event's own location is the button's center, not where the
        // click landed, so read the cursor itself.
        let x = NSEvent.mouseLocation.x - (button.window?.frame.minX ?? 0) - imageOffset(in: button)
        guard let index = kindIndex(at: x), kinds.indices.contains(index),
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
        open(kind, at: index, from: button)
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

    private func open(_ kind: ProviderKind, at index: Int, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        // Left edge lined up with the provider's segment, top a few points below the bar.
        let segmentX = spans.indices.contains(index) && index > 0
            ? window.frame.minX + imageOffset(in: button) + spans[index].lowerBound
            : window.frame.minX
        let panel = DropdownPanel(
            content: Self.dropdown(for: kind, store: store),
            anchor: NSPoint(x: segmentX, y: window.frame.minY - 3),
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
            item.button?.highlight(false)
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
