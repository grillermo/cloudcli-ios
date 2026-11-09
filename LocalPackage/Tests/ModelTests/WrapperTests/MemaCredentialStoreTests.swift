import Foundation
import Testing

@testable import DataSource

private final class FakeVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var refuseWrites = false

    func read() -> Data? { lock.withLock { data } }
    func write(_ newValue: Data) -> Bool {
        lock.withLock {
            if refuseWrites { return false }
            data = newValue
            return true
        }
    }
    func remove() { lock.withLock { data = nil } }
}

struct MemaCredentialStoreTests {
    private func makeStore(vault: any TokenVault = FakeVault()) -> (MemaCredentialStore, () -> Void) {
        let id = UUID().uuidString
        let suite = "mema-test-\(id)"
        let store = MemaCredentialStore(vault: vault, defaultsSuite: suite)
        return (store, {
            store.delete()
            UserDefaults().removePersistentDomain(forName: suite)
        })
    }

    @Test
    func round_trips_and_replaces() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        #expect(store.load() == nil)

        let first = MemaCredentials(baseURL: URL(string: "https://one.example")!, token: "fake-one")
        #expect(store.save(first))
        #expect(store.load() == first)

        let second = MemaCredentials(baseURL: URL(string: "https://two.example")!, token: "fake-two")
        #expect(store.save(second))
        #expect(store.load() == second)
    }

    @Test
    func keeps_the_token_out_of_user_defaults() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        #expect(store.save(MemaCredentials(baseURL: URL(string: "https://one.example")!, token: "fake-secret-xyz")))
        let dump = String(describing: UserDefaults(suiteName: store.defaultsSuite)?.dictionaryRepresentation() ?? [:])
        #expect(!dump.contains("fake-secret-xyz"))
    }

    @Test
    func load_is_nil_when_only_one_half_exists() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        UserDefaults(suiteName: store.defaultsSuite)?.set("https://one.example", forKey: "mema-base-url")
        #expect(store.load() == nil)
    }

    @Test
    func a_refused_token_write_saves_nothing() {
        let vault = FakeVault()
        let (store, cleanup) = makeStore(vault: vault)
        defer { cleanup() }
        let first = MemaCredentials(baseURL: URL(string: "https://one.example")!, token: "fake-one")
        #expect(store.save(first))

        vault.refuseWrites = true
        let second = MemaCredentials(baseURL: URL(string: "https://two.example")!, token: "fake-two")
        #expect(!store.save(second))
        #expect(store.load() == first)
    }

    @Test
    func delete_clears_both_halves() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.save(MemaCredentials(baseURL: URL(string: "https://one.example")!, token: "fake-one"))
        store.delete()
        #expect(store.load() == nil)
    }

    /// The unhosted test process has no keychain entitlement (-34018), so this
    /// runs only where the real Keychain is usable (a hosted run, a device).
    @Test(.enabled(if: Self.keychainUsable))
    func the_real_keychain_round_trips() {
        let id = UUID().uuidString
        let vault = KeychainTokenVault(service: "me.chiq.cloudcli.mema.test.\(id)")
        defer { vault.remove() }
        #expect(vault.read() == nil)
        #expect(vault.write(Data("fake-one".utf8)))
        #expect(vault.write(Data("fake-two".utf8)))
        #expect(vault.read() == Data("fake-two".utf8))
        vault.remove()
        #expect(vault.read() == nil)
    }

    private static var keychainUsable: Bool {
        let vault = KeychainTokenVault(service: "me.chiq.cloudcli.mema.probe.\(UUID().uuidString)")
        defer { vault.remove() }
        return vault.write(Data("probe".utf8))
    }
}
