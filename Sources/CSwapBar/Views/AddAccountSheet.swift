import SwiftUI

/// Presented via WindowPresenter as a standalone NSWindow, not `.sheet` --
/// see WindowPresenter.swift for why.
struct AddAccountSheet: View {
    static let windowID = "add-token"

    @EnvironmentObject var state: AppState
    @State private var token: String = ""
    @State private var email: String = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add account from setup-token")
                .font(.system(size: 13, weight: .semibold))

            Text("Paste a setup-token or API key (cswap add-token). Leave email blank to auto-generate one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-oat01-… or setup-token", text: $token)
                .textFieldStyle(.roundedBorder)

            TextField("Email (optional)", text: $email)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { WindowPresenter.shared.close(id: Self.windowID) }
                Button("Add") {
                    isSubmitting = true
                    Task {
                        await state.addToken(token, email: email.isEmpty ? nil : email)
                        isSubmitting = false
                        WindowPresenter.shared.close(id: Self.windowID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
