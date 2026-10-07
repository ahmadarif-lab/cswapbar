import AppKit
import SwiftUI

struct KiroDropdownExtras: View {
    @ObservedObject var provider: KiroProvider

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.isConfigured {
            ActionRow(icon: "arrow.clockwise", title: "Read kiro-cli usage again") {
                Task { await provider.refresh() }
            }
        } else {
            ActionRow(icon: "questionmark.circle", title: "How to connect…") {
                SettingsWindow.show(page: .kiro)
            }
        }
    }
}
