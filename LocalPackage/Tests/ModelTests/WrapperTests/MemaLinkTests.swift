import Foundation
import Testing

@testable import DataSource
@testable import Model

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

struct MemaLinkParserTests {
    private func parse(_ text: String) -> MemaLink? {
        URL(string: text).flatMap { MemaCredentials.parse(link: $0) }
    }

    @Test(arguments: ["fonos", "cloudcli", "FONOS"])
    func valid_link(scheme: String) throws {
        let link = try #require(parse("\(scheme)://model?name=mema-qwen&base_url=http://192.168.1.3:8787&model=qwen&api_key=0923093FAKEKEY"))
        #expect(link.name == "mema-qwen")
        #expect(link.credentials.baseURL.absoluteString == "http://192.168.1.3:8787")
        #expect(link.credentials.token == "0923093FAKEKEY")
        #expect(link.serverHost == "192.168.1.3")
    }

    @Test
    func percent_encoded_values_and_v1() throws {
        let link = try #require(parse("fonos://model?name=My%20Mema&base_url=http%3A%2F%2F192.168.1.3%3A8787%2Fv1%2F&api_key=a%2Bb%3D"))
        #expect(link.name == "My Mema")
        #expect(link.credentials.baseURL.absoluteString == "http://192.168.1.3:8787")
        #expect(link.credentials.token == "a+b=")
    }

    @Test
    func missing_name_falls_back_to_host() throws {
        let link = try #require(parse("fonos://model?base_url=https://mema.example&api_key=k"))
        #expect(link.name == "mema.example")
    }

    @Test(arguments: [
        "https://model?base_url=http://a.example&api_key=k",
        "fonos://other?base_url=http://a.example&api_key=k",
        "cloudcli://session/abc",
        "fonos://model",
        "fonos://model?base_url=http://a.example",
        "fonos://model?api_key=k",
        "fonos://model?base_url=http://a.example&api_key=",
        "fonos://model?base_url=&api_key=k",
        "fonos://model?base_url=ftp://a.example&api_key=k",
        "fonos://model?base_url=http://a.example?x=1&api_key=k",
        "fonos://model?base_url=http://u:p@a.example&api_key=k",
        "fonos://model?base_url=http://a.example&api_key=a%20b",
    ])
    func rejects_invalid(text: String) {
        #expect(parse(text) == nil)
    }

    @Test
    func description_hides_the_key() throws {
        let link = try #require(parse("fonos://model?base_url=http://a.example&api_key=SECRETKEY"))
        #expect(!"\(link)".contains("SECRETKEY"))
        #expect(!String(reflecting: link).contains("SECRETKEY"))
    }
}

@MainActor
struct MemaLinkImportTests {
    private let good = URL(string: "fonos://model?name=mema&base_url=http://192.168.1.3:8787&api_key=NEWKEY")!

    private func makeStore(_ vault: FakeVault) -> MemaCredentialStore {
        MemaCredentialStore(vault: vault, defaultsSuite: "mema-link-test-\(UUID().uuidString)")
    }

    @Test
    func opening_a_link_saves_nothing_until_confirmed() throws {
        let store = makeStore(FakeVault())
        let old = MemaCredentials(baseURL: URL(string: "https://old.example")!, token: "OLD")
        #expect(store.save(old))
        let sut = MemaLinkImport(save: { store.save($0) })

        #expect(sut.handle(good))
        #expect(sut.isPresentedConfirmation)
        #expect(sut.confirmationTitle == "Use mema for dictation?")
        #expect(sut.confirmationMessage.contains("192.168.1.3"))
        #expect(!sut.confirmationMessage.contains("NEWKEY"))
        #expect(store.load() == old)

        sut.cancel()
        #expect(!sut.isPresentedConfirmation)
        #expect(store.load() == old)
    }

    @Test
    func confirm_saves_and_load_returns_the_new_credentials() throws {
        let store = makeStore(FakeVault())
        let sut = MemaLinkImport(save: { store.save($0) })
        sut.handle(good)
        sut.confirm()
        let loaded = try #require(store.load())
        #expect(loaded.baseURL.absoluteString == "http://192.168.1.3:8787")
        #expect(loaded.token == "NEWKEY")
        #expect(sut.pending == nil)
        #expect(sut.errorMessage == nil)
    }

    @Test
    func keychain_refusal_reports_nothing_saved() {
        let vault = FakeVault()
        vault.refuseWrites = true
        let store = makeStore(vault)
        let sut = MemaLinkImport(save: { store.save($0) })
        sut.handle(good)
        sut.confirm()
        #expect(store.load() == nil)
        #expect(sut.errorMessage?.contains("nothing was saved") == true)
    }

    @Test
    func invalid_model_link_is_consumed_with_an_error() {
        let sut = MemaLinkImport(save: { _ in Issue.record("must not save"); return true })
        #expect(sut.handle(URL(string: "fonos://model?base_url=http://a.example")!))
        #expect(sut.pending == nil)
        #expect(sut.errorMessage != nil)
    }

    @Test
    func other_links_are_ignored() {
        let sut = MemaLinkImport(save: { _ in true })
        #expect(!sut.handle(URL(string: "cloudcli://session/abc")!))
        #expect(!sut.handle(URL(string: "https://model?api_key=k")!))
        #expect(!sut.handle(URL(string: "fonos://other")!))
        #expect(sut.pending == nil && sut.errorMessage == nil)
    }
}
