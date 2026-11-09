import Foundation
import Testing

@testable import DataSource

struct MemaCredentialsTests {
    @Test
    func parses_the_two_pasted_lines() throws {
        let value = try #require(MemaCredentials.parsePasted(
            "VOICE_API_BASE_URL=https://mema.example/v1/\nVOICE_API_KEY=abc\n"
        ))
        #expect(value.baseURL.absoluteString == "https://mema.example")
        #expect(value.token == "abc")
    }

    @Test
    func strips_quotes() throws {
        let value = try #require(MemaCredentials.parsePasted(
            "VOICE_API_KEY=\"abc\"\nVOICE_API_BASE_URL='https://mema.example'"
        ))
        #expect(value.baseURL.absoluteString == "https://mema.example")
        #expect(value.token == "abc")
    }

    @Test
    func rejects_incomplete_text() {
        #expect(MemaCredentials.parsePasted("VOICE_API_KEY=abc") == nil)
        #expect(MemaCredentials.parsePasted("hello") == nil)
    }

    @Test
    func accepts_export_prefixes_comments_and_crlf() throws {
        let value = try #require(MemaCredentials.parsePasted(
            "# mema\r\nexport VOICE_API_BASE_URL=https://mema.example\r\nexport VOICE_API_KEY=abc\r\n"
        ))
        #expect(value.baseURL.absoluteString == "https://mema.example")
        #expect(value.token == "abc")
    }

    @Test
    func keeps_equals_signs_inside_the_token() throws {
        let value = try #require(MemaCredentials.parsePasted(
            "VOICE_API_BASE_URL=https://mema.example\nVOICE_API_KEY=ab==\n"
        ))
        #expect(value.token == "ab==")
    }

    @Test
    func normalises_the_url() throws {
        func base(_ text: String) -> String? {
            MemaCredentials(urlText: text, token: "t")?.baseURL.absoluteString
        }
        #expect(base("  https://mema.example/v1  \n") == "https://mema.example")
        #expect(base("https://mema.example///") == "https://mema.example")
        #expect(base("https://mema.example/v1/") == "https://mema.example")
        #expect(base("http://192.168.1.3:8000/v1") == "http://192.168.1.3:8000")
        #expect(base("https://mema.example/api") == "https://mema.example/api")
        #expect(base("mema.example") == "https://mema.example")
        #expect(base("HTTPS://mema.example") != nil)
    }

    @Test
    func rejects_unusable_urls_and_empty_tokens() {
        #expect(MemaCredentials(urlText: "", token: "t") == nil)
        #expect(MemaCredentials(urlText: "ftp://mema.example", token: "t") == nil)
        #expect(MemaCredentials(urlText: "file:///etc/passwd", token: "t") == nil)
        #expect(MemaCredentials(urlText: "https://", token: "t") == nil)
        #expect(MemaCredentials(urlText: "https://user:pw@mema.example", token: "t") == nil)
        #expect(MemaCredentials(urlText: "https://mema.example?key=1", token: "t") == nil)
        #expect(MemaCredentials(urlText: "https://mema.example", token: "  \n") == nil)
    }

    @Test
    func trims_the_token() {
        #expect(MemaCredentials(urlText: "https://mema.example", token: " abc\n")?.token == "abc")
    }

    @Test
    func never_prints_the_token() {
        let value = MemaCredentials(baseURL: URL(string: "https://mema.example")!, token: "fake-secret-123")
        #expect(!String(describing: value).contains("fake-secret-123"))
        #expect(!String(reflecting: value).contains("fake-secret-123"))
        #expect(!"\(value)".contains("fake-secret-123"))
    }
}
