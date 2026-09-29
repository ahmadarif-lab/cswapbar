import AppKit
import SwiftUI

/// Settings in a real NSWindow: a menu bar app has no main window for a
/// SwiftUI `Settings` scene to hang off, and the dropdown panel closes
/// itself on the same click that would present a sheet.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// The app's one provider store, handed over at launch so the status bar
    /// controller's right-click menu can open Settings too.
    static weak var store: ProviderStore?

    static func show() {
        guard let store else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "CSwapBar Settings"
            // The centred title would straddle the preview and the options;
            // every page carries its own heading instead.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(store.updater))
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { close() }
            }
            self.window = window
        }
        applyDockPolicy()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops the whole view tree so the preview's dropdown stops counting
    /// as open.
    private static func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
        applyDockPolicy()
    }

    /// CSwapBar lives in the menu bar; it takes a Dock icon only while this
    /// window is open, so ⌘W/⌘Q and window management behave normally here.
    static func applyDockPolicy() {
        NSApp.setActivationPolicy(window != nil ? .regular : .accessory)
    }
}
