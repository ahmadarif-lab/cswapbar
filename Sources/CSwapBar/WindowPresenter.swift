import AppKit
import SwiftUI

/// Shows SwiftUI content in a real, independent NSWindow.
///
/// SwiftUI's `.sheet`/`.confirmationDialog`/`.alert` attach to the presenting
/// window -- inside a MenuBarExtra(.window) popover, that window dismisses
/// itself on the same click that would trigger the presentation, so those
/// modifiers never actually show anything. A plain NSWindow sidesteps that.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        window.contentView = NSHostingView(rootView: content())
        window.delegate = self
        windows[id] = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key
        else { return }
        windows.removeValue(forKey: key)
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
