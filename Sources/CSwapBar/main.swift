import AppKit

// Plain AppKit entry point: CSwapBar's UI is one status item per provider
// plus an ordinary settings window, so there's no SwiftUI App scene to host
// (see StatusBarController.swift for why it isn't a MenuBarExtra).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication holds its delegate weakly; `run()` never returns, so
    // this local keeps it alive for the app's lifetime.
    withExtendedLifetime(delegate) { app.run() }
}
