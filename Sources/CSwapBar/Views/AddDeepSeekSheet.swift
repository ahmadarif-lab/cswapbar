import SwiftUI

/// Presented via WindowPresenter as a standalone NSWindow, not `.sheet` --
/// see WindowPresenter.swift for why.
struct AddDeepSeekSheet: View {
    static let windowID = "add-deepseek"

    @EnvironmentObject var provider: DeepSeekProvider
    @State private var apiKey: String = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add DeepSeek account")
                .font(.system(size: 13, weight: .semibold))

            Text("Paste an API key from platform.deepseek.com → API keys.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("API key", text: $apiKey) // plain, not SecureField -- see AddZAISheet for why
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { WindowPresenter.shared.close(id: Self.windowID) }
                Button("Add") {
                    isSubmitting = true
                    Task {
                        await provider.setAPIKey(apiKey)
                        isSubmitting = false
                        WindowPresenter.shared.close(id: Self.windowID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
