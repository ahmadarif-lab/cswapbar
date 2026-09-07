import AppKit
import SwiftUI

@main
struct CSwapBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps a single menu bar icon around: launchd starts the binary directly
/// while a double-click goes through LaunchServices, so both can run at once.
/// The younger instance steps aside.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
            .contains { other in
                guard let otherDate = other.launchDate, let myDate = me.launchDate else { return false }
                return otherDate < myDate
            }
        if older {
            NSApp.terminate(nil)
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState

    private var usage: Usage? { state.activeAccount?.usage }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.make(
                fiveHour: usage?.fiveHour?.pct,
                sevenDay: usage?.sevenDay?.pct
            ))
            if let pct = usage?.fiveHour?.pct {
                Text("\(Int(pct))%")
            }
        }
    }
}
