import Foundation
import Testing

@testable import Model

struct NativeBridgeSupportTests {
    @Test
    func ready_is_accepted_only_from_the_main_frame_of_the_app_origin() {
        let body: [String: Any] = ["type": "ready", "buildId": "b1"]
        #expect(NativeBridgeSupport.parseReady(body: body, isMainFrame: true, scheme: "cloudcli", host: "app")
            == .init(buildID: "b1"))
        #expect(NativeBridgeSupport.parseReady(body: body, isMainFrame: false, scheme: "cloudcli", host: "app") == nil)
        #expect(NativeBridgeSupport.parseReady(body: body, isMainFrame: true, scheme: "https", host: "claude.chiq.me") == nil)
        #expect(NativeBridgeSupport.parseReady(body: body, isMainFrame: true, scheme: "cloudcli", host: "evil") == nil)
        #expect(NativeBridgeSupport.parseReady(body: ["type": "other"], isMainFrame: true, scheme: "cloudcli", host: "app") == nil)
        #expect(NativeBridgeSupport.parseReady(body: "ready", isMainFrame: true, scheme: "cloudcli", host: "app") == nil)
        #expect(NativeBridgeSupport.parseReady(body: ["type": "ready"], isMainFrame: true, scheme: "cloudcli", host: "app")
            == .init(buildID: nil))
    }

    @Test
    func only_the_app_page_receives_dictation() {
        #expect(NativeBridgeSupport.isAppPage(URL(string: "cloudcli://app/")))
        #expect(NativeBridgeSupport.isAppPage(URL(string: "cloudcli://app/session/x")))
        #expect(!NativeBridgeSupport.isAppPage(URL(string: "https://claude.chiq.me/")))
        #expect(!NativeBridgeSupport.isAppPage(URL(string: "cloudcli://app.evil/")))
        #expect(!NativeBridgeSupport.isAppPage(nil))
    }

    @Test(arguments: [
        "plain", "it's \"quoted\"", "back\\slash", "line1\r\nline2", "sep\u{2028}and\u{2029}",
        "</script><script>alert(1)</script>", "`tick`", "${process.env}", "\u{0}nul", "emoji 🎙",
    ])
    func insert_script_carries_the_text_as_one_inert_literal(_ text: String) throws {
        let script = try #require(NativeBridgeSupport.insertScript(for: text))
        let prefix = "window.__nativeDictation ? window.__nativeDictation.insert("
        let suffix = "[0]) : false"
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(suffix))
        let literal = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(!literal.contains("\u{2028}") && !literal.contains("\u{2029}"))
        #expect(!literal.contains("\n") && !literal.contains("\r"))
        // The literal is a JSON array holding exactly the original text.
        let data = Data(literal.utf8)
        #expect(try JSONDecoder().decode([String].self, from: data) == [text])
    }

    @Test(arguments: ["/abc", "/abc%2Fd", "/a.b_c~d-1"])
    func session_ids_that_are_one_safe_segment_open(_ path: String) {
        #expect(NativeBridgeSupport.sessionTarget(path: path)?.absoluteString == "cloudcli://app/session\(path)")
    }

    @Test(arguments: ["", "/", "/..", "/.", "/%2E%2E", "/a/b", "/a b", "/a?x", "/a#x", "/%2e%2e", "/a\\b"])
    func other_session_ids_are_ignored(_ path: String) {
        #expect(NativeBridgeSupport.sessionTarget(path: path) == nil)
    }
}
