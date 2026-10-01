import AppKit
import SwiftUI

struct OpenCodeGoDropdownExtras: View {
    @ObservedObject var provider: OpenCodeGoProvider

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.isConfigured {
            ActionRow(icon: "arrow.clockwise", title: "Re-read OpenCode credential") {
                Task { await provider.refresh() }
            }
            ActionRow(icon: "doc.text.magnifyingglass", title: "Reveal credential in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([provider.credentialFileURL])
            }
        } else {
            ActionRow(icon: "questionmark.circle", title: "How to connect…") {
                SettingsWindow.show(page: .opencodeGo)
            }
        }
    }
}
