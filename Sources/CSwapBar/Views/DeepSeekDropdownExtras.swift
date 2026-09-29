import AppKit
import SwiftUI

struct DeepSeekDropdownExtras: View {
    @ObservedObject var provider: DeepSeekProvider

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.isConfigured {
            ActionRow(icon: "creditcard", title: "Top up on platform.deepseek.com") {
                if let url = URL(string: "https://platform.deepseek.com/top_up") {
                    NSWorkspace.shared.open(url)
                }
            }
            ActionRow(icon: "key", title: "Update API key…") {
                openSheet()
            }
            ActionRow(icon: "trash", title: "Remove account", tint: Theme.high) {
                provider.removeCredential()
            }
        } else {
            ActionRow(icon: "key", title: "Add account…") {
                openSheet()
            }
        }
    }

    private func openSheet() {
        WindowPresenter.shared.show(id: AddDeepSeekSheet.windowID, title: "Add DeepSeek account", size: NSSize(width: 320, height: 160)) {
            AddDeepSeekSheet().environmentObject(provider)
        }
    }
}
