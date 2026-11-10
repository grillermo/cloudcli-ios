import Model
import SwiftUI

struct WrapperOverlay: View {
    let services: AppServices
    @Environment(\.openURL) private var openURL

    private var updater: BuildUpdater { services.updater }
    private var dictation: DictationController { services.dictation }

    var body: some View {
        VStack(spacing: 8) {
            if dictation.failedCount > 0 {
                failedBar
            }
            if let message = updater.rollbackMessage {
                Button(message) { updater.rollbackMessage = nil }
                    .font(.footnote)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            if updater.pendingBuildID != nil {
                Button("New build") { Task { await updater.applyPending() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
            }
            Spacer()
            HStack {
                dictationControl
                Spacer()
            }
            .padding(20)
        }
        .alert("Microphone access is off", isPresented: Binding(
            get: { dictation.permissionDenied },
            set: { dictation.permissionDenied = $0 }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var failedBar: some View {
        HStack {
            Text("Transcription failed").font(.footnote.weight(.semibold))
            Spacer()
            Button(dictation.isRetrying ? "Retrying…" : "Retry and copy") {
                Task { await dictation.retryAndCopyTapped() }
            }
            .disabled(dictation.isRetrying)
            Button("Dismiss", systemImage: "xmark") { dictation.dismissFailedTapped() }
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(10)
        .background(.red)
    }

    @ViewBuilder
    private var dictationControl: some View {
        switch dictation.state {
        case .idle:
            control("mic.fill", label: "Dictate") { await dictation.voiceTapped() }
        case .recording:
            HStack(spacing: 12) {
                control("stop.fill", label: "Stop", tint: .red) { await dictation.stopTapped() }
                control("xmark", label: "Cancel", tint: .gray) { dictation.cancelTapped() }
            }
        case .transcribing:
            ProgressView().padding(14).background(.regularMaterial, in: Circle())
        case .readyToSend:
            control("return", label: "Send") { await dictation.returnTapped() }
        }
    }

    private func control(
        _ systemImage: String,
        label: String,
        tint: Color = .accentColor,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .foregroundStyle(.white)
                .background(tint, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct FirstDownloadView: View {
    let isChecking: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("CloudCLI needs a connection for its first download.")
                .multilineTextAlignment(.center)
            Button(isChecking ? "Checking…" : "Retry", action: retry)
                .disabled(isChecking)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
