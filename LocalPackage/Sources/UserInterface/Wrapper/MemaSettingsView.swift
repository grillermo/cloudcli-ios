import DataSource
import SwiftUI
import UIKit

struct MemaSettingsView: View {
    let store: MemaCredentialStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mema server") {
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Bearer token", text: $token)
                }
                Section {
                    Button("Paste from clipboard", action: paste)
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("Dictation")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let saved = store.load() {
                    urlText = saved.baseURL.absoluteString
                    token = saved.token
                }
            }
        }
    }

    private func paste() {
        guard let value = UIPasteboard.general.string.flatMap(MemaCredentials.parsePasted) else {
            message = "The clipboard does not hold the two VOICE_API lines."
            return
        }
        urlText = value.baseURL.absoluteString
        token = value.token
        message = nil
    }

    private func save() {
        guard let value = MemaCredentials(urlText: urlText, token: token) else {
            message = "Enter a full URL and a token."
            return
        }
        guard store.save(value) else {
            message = "The Keychain refused the token, so nothing was saved."
            return
        }
        dismiss()
    }
}
