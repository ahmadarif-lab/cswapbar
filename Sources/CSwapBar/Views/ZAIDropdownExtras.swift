import AppKit
import SwiftUI

struct ZAIDropdownExtras: View {
    @ObservedObject var provider: ZAIProvider

    var body: some View {
        SectionDivider()
        SectionHeader(title: "Manage")
        if provider.isConfigured {
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
        WindowPresenter.shared.show(id: AddZAISheet.windowID, title: "Add z.ai account", size: NSSize(width: 320, height: 220)) {
            AddZAISheet().environmentObject(provider)
        }
    }
}
