import Foundation
import Security

/// Where the bearer token is kept. The Keychain in the app; a fake in tests
/// that run without keychain entitlements.
protocol TokenVault: Sendable {
    func read() -> Data?
    func write(_ data: Data) -> Bool
    func remove()
}

struct KeychainTokenVault: TokenVault {
    let service: String
    let account = "bearerToken"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The base URL lives in UserDefaults; the bearer token only in the Keychain.
public struct MemaCredentialStore: Sendable {
    private static let urlKey = "mema-base-url"
    private let vault: any TokenVault
    public let defaultsSuite: String?

    public init(service: String = "me.chiq.cloudcli.mema", defaultsSuite: String? = nil) {
        self.init(vault: KeychainTokenVault(service: service), defaultsSuite: defaultsSuite)
    }

    init(vault: any TokenVault, defaultsSuite: String? = nil) {
        self.vault = vault
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() -> MemaCredentials? {
        guard let url = defaults.string(forKey: Self.urlKey),
              let data = vault.read(),
              let token = String(data: data, encoding: .utf8) else { return nil }
        return MemaCredentials(urlText: url, token: token)
    }

    /// Returns false when the Keychain refused the token; the stored URL is left
    /// as it was, so a half-saved pair cannot appear.
    @discardableResult
    public func save(_ credentials: MemaCredentials) -> Bool {
        guard vault.write(Data(credentials.token.utf8)) else { return false }
        defaults.set(credentials.baseURL.absoluteString, forKey: Self.urlKey)
        return true
    }

    public func delete() {
        vault.remove()
        defaults.removeObject(forKey: Self.urlKey)
    }
}
