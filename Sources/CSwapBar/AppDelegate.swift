import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherCopyIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        ProviderSettings.registerDefaults()

        let store = ProviderStore()
        self.store = store
        SettingsWindow.store = store
        statusBar = StatusBarController(store: store)
        store.applyEnabledProvidersFromSettings()
        NSApp.mainMenu = Self.mainMenu()
        SettingsWindow.applyDockPolicy()

        LoginItem.enableOnFirstLaunch()
    }

    /// Without a SwiftUI `App` scene, nothing builds the standard Edit menu
    /// a normal Mac app gets for free -- and without it, Cmd+V/C/X/A in any
    /// text field (the Settings window, the "Add account" sheets) silently
    /// does nothing, since AppKit resolves those key equivalents through the
    /// menu bar. Shown only while a window makes CSwapBar a regular app.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit CSwapBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    /// launchd starts the binary directly while a double-click goes through
    /// LaunchServices, so both can run at once. The younger instance steps aside.
    private func anotherCopyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
            .contains { other in
                guard let otherDate = other.launchDate, let myDate = me.launchDate else { return false }
                return otherDate < myDate
            }
    }
}
