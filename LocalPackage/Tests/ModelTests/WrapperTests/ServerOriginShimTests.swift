import JavaScriptCore
import Testing

@testable import DataSource

struct ServerOriginShimTests {
    private func run(_ call: String) -> String? {
        let context = JSContext()!
        context.evaluateScript("""
        var calls = [];
        var window = this;
        var location = { origin: 'cloudcli://app' };
        function fetch(u) { calls.push(String(u)); }
        function WebSocket(u) { calls.push(u); }
        function EventSource(u) { calls.push(u); }
        function XMLHttpRequest() {}
        XMLHttpRequest.prototype.open = function (m, u) { calls.push(u); };
        """)
        context.evaluateScript(ServerOriginShim.source)
        context.evaluateScript(call)
        return context.evaluateScript("calls[0]")?.toString()
    }

    @Test(arguments: [
        ("fetch('/api/x')", "https://claude.chiq.me/api/x"),
        ("fetch('cloudcli://app/api/x')", "https://claude.chiq.me/api/x"),
        ("fetch('/assets/a.js')", "/assets/a.js"),
        ("fetch('/apiary')", "/apiary"),
        ("new EventSource('/api/stream?a=1')", "https://claude.chiq.me/api/stream?a=1"),
        ("new WebSocket('ws://app/ws?token=t')", "wss://claude.chiq.me/ws?token=t"),
        ("new WebSocket('ws://app/shell')", "wss://claude.chiq.me/shell"),
        ("new WebSocket('wss://example.com/ws')", "wss://example.com/ws"),
        ("new XMLHttpRequest().open('GET', '/api/x')", "https://claude.chiq.me/api/x"),
    ])
    func rewrites(call: String, expected: String) {
        #expect(run(call) == expected)
    }
}
