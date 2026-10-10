import AppKit
import SwiftUI

struct CodexDropdownExtras: View {
    @ObservedObject var provider: CodexProvider

    var body: some View {
        if provider.isConfigured {
            WarmupDropdownSection(provider: provider)
        }
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.isConfigured {
            ActionRow(icon: "arrow.clockwise", title: "Re-read Codex login") {
                Task { await provider.refresh() }
            }
        } else {
            ActionRow(icon: "questionmark.circle", title: "How to connect…") {
                SettingsWindow.show(page: .codex)
            }
        }
    }
}
