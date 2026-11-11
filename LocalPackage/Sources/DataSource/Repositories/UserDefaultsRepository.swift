import Foundation

public struct UserDefaultsRepository: Sendable {
    private var userDefaultsClient: UserDefaultsClient

    public init(_ userDefaultsClient: UserDefaultsClient) {
        self.userDefaultsClient = userDefaultsClient

#if DEBUG
        if ProcessInfo.needsResetUserDefaults {
            userDefaultsClient.removePersistentDomain(Bundle.main.bundleIdentifier!)
        }
        showAllData()
#endif
    }

    /// The last page the web view showed, so a relaunch can return to it.
    public var lastURL: URL? {
        get { userDefaultsClient.string(Self.lastURLKey).flatMap { URL(string: $0) } }
        nonmutating set { userDefaultsClient.setString(newValue?.absoluteString, Self.lastURLKey) }
    }

    static let lastURLKey = "lastURL"

    private func showAllData() {
        guard let dict = userDefaultsClient.persistentDomain(Bundle.main.bundleIdentifier!) else {
            return
        }
        for (key, value) in dict.sorted(by: { $0.0 < $1.0 }) {
            Swift.print("\(key) => \(value)")
        }
    }
}
