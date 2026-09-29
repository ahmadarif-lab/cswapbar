import SwiftUI

/// Presented via WindowPresenter as a standalone NSWindow, not `.sheet` --
/// see WindowPresenter.swift for why.
struct AddAntigravitySheet: View {
    static let windowID = "add-antigravity"

    @EnvironmentObject var provider: AntigravityProvider
    @State private var showManualEntry = false
    @State private var manualToken: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Antigravity account")
                .font(.system(size: 13, weight: .semibold))

            Text("Quota already shows automatically whenever the agy CLI is running a session -- nothing to set up for that. This connects a fallback account for when no session is active, by reading the login the agy CLI already stored on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = provider.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.high)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if provider.isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button("Auto-detect") {
                    Task {
                        await provider.autoDetect()
                        if provider.errorMessage == nil { WindowPresenter.shared.close(id: Self.windowID) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provider.isConnecting)
            }

            DisclosureGroup("Paste a refresh token manually", isExpanded: $showManualEntry) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The `refresh_token` value from `~/.gemini/jetski-standalone-oauth-token`'s `token` object.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Plain, not SecureField -- see AddZAISheet for why.
                    TextField("Google OAuth refresh token", text: $manualToken)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Connect") {
                            Task {
                                await provider.connectWithManualToken(manualToken)
                                if provider.errorMessage == nil { WindowPresenter.shared.close(id: Self.windowID) }
                            }
                        }
                        .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty || provider.isConnecting)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))

            HStack {
                Spacer()
                Button("Close") { WindowPresenter.shared.close(id: Self.windowID) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
