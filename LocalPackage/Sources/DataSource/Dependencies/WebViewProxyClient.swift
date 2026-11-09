import Foundation
import os
import WebUI

public struct WebViewProxyClient: DependencyClient {
    public var setProxy: @Sendable (WebViewProxy) -> Void
    public var url: @Sendable () async -> URL?
    public var load: @Sendable (URLRequest) async -> Void
    public var loadHTMLString: @Sendable (String, URL?) async -> Void
    public var evaluateJavaScript: @Sendable (String) async -> Bool
    public var canGoBack: @Sendable () async -> Bool
    public var goBack: @Sendable () async -> Void
    public var canGoForward: @Sendable () async -> Bool
    public var goForward: @Sendable () async -> Void

    public static let liveValue: Self = {
        let _proxy = OSAllocatedUnfairLock<WebViewProxy?>(initialState: nil)

        @Sendable
        func proxy(line: UInt = #line) -> WebViewProxy {
            guard let proxy = _proxy.withLock(\.self) else {
                fatalError("line \(line): proxy must not be nil.")
            }
            return proxy
        }

        return Self(
            setProxy: { proxy in
                _proxy.withLock { $0 = proxy}
            },
            url: { await proxy().url },
            load: { await proxy().load(request: $0) },
            loadHTMLString: { await proxy().loadHTMLString($0, baseURL: $1) },
            evaluateJavaScript: { script in
                // The result is not Sendable, so it is reduced to a Bool on the main actor.
                await Task { @MainActor in
                    ((try? await proxy().evaluateJavaScript(script)) as? Bool) ?? false
                }.value
            },
            canGoBack: { await proxy().canGoBack },
            goBack: { await proxy().goBack() },
            canGoForward: { await proxy().canGoForward },
            goForward: { await proxy().goForward() }
        )
    }()

    public static let testValue = Self(
        setProxy: { _ in },
        url: { nil },
        load: { _ in },
        loadHTMLString: { _, _ in },
        evaluateJavaScript: { _ in false },
        canGoBack: { false },
        goBack: {},
        canGoForward: { false },
        goForward: {}
    )
}
