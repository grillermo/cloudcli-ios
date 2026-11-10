import DataSource
import Foundation
import Observation

/// Receives dictation credentials from a link. Nothing is saved until the user confirms,
/// because a malicious link could point the dictation audio at another server.
@MainActor @Observable public final class MemaLinkImport {
    public private(set) var pending: MemaLink?
    public private(set) var errorMessage: String?
    private let save: @MainActor (MemaCredentials) -> Bool

    public init(save: @escaping @MainActor (MemaCredentials) -> Bool) {
        self.save = save
    }

    public var isPresentedConfirmation: Bool {
        get { pending != nil }
        set { if !newValue { pending = nil } }
    }

    public var isPresentedError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    public var confirmationTitle: String { "Use \(pending?.name ?? "") for dictation?" }
    public var confirmationMessage: String {
        "Your dictation audio will be sent to \(pending?.serverHost ?? ""). Only save this if you trust the link."
    }

    /// True when the link is a credentials link and was consumed here; other links return false.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), MemaCredentials.linkSchemes.contains(scheme),
              url.host()?.lowercased() == MemaCredentials.linkHost else { return false }
        if let link = MemaCredentials.parse(link: url) {
            pending = link
            errorMessage = nil
        } else {
            pending = nil
            errorMessage = "This dictation link is not valid, so nothing was saved."
        }
        return true
    }

    public func confirm() {
        guard let link = pending else { return }
        pending = nil
        if !save(link.credentials) {
            errorMessage = "The Keychain refused the token, so nothing was saved."
        }
    }

    public func cancel() { pending = nil }
}
