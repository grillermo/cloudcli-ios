import WebKit

extension WKWebViewConfiguration {
    @MainActor
    static var forTelescopure: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsInlinePredictions = true
        configuration.applicationNameForUserAgent = "Safari/604.1"
        return configuration
    }
}
