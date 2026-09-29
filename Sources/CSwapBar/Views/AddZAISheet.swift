import SwiftUI
import ZAIEngine

/// Presented via WindowPresenter as a standalone NSWindow, not `.sheet` --
/// see WindowPresenter.swift for why.
struct AddZAISheet: View {
    static let windowID = "add-zai"

    @EnvironmentObject var provider: ZAIProvider
    @State private var apiKey: String = ""
    @State private var region: ZAIRegion = .global
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add z.ai account")
                .font(.system(size: 13, weight: .semibold))

            Text("Paste your z.ai API key (from z.ai's own Settings → API keys page).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Plain, not SecureField: SecureField doesn't reliably accept
            // paste in this app's borderless-panel/no-Edit-menu window
            // context, and these keys are long enough that typing one by
            // hand isn't realistic.
            TextField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Picker("Region", selection: $region) {
                ForEach(ZAIRegion.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Spacer()
                Button("Cancel") { WindowPresenter.shared.close(id: Self.windowID) }
                Button("Add") {
                    isSubmitting = true
                    Task {
                        await provider.setAPIKey(apiKey, region: region)
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
