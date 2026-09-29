import AppKit
import SwiftUI

struct AntigravityDropdownExtras: View {
    @ObservedObject var provider: AntigravityProvider

    var body: some View {
        if provider.isConfigured {
            WarmupDropdownSection(provider: provider)
        }
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.hasStoredCredential {
            ActionRow(icon: "arrow.clockwise", title: "Re-detect account") {
                Task { await provider.autoDetect() }
            }
            ActionRow(icon: "trash", title: "Remove account", tint: Theme.high) {
                provider.removeCredential()
            }
        } else {
            ActionRow(icon: "key", title: "Add fallback account…") {
                openSheet()
            }
        }
    }

    private func openSheet() {
        WindowPresenter.shared.show(id: AddAntigravitySheet.windowID, title: "Add Antigravity account", size: NSSize(width: 340, height: 260)) {
            AddAntigravitySheet().environmentObject(provider)
        }
    }
}
