import DataSource
import Foundation
import WebKit

public final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    private let location: BuildLocation

    public init(location: BuildLocation) {
        self.location = location
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let root = location.current,
              let resolved = AppSchemeResolver.resolve(url, root: root),
              let data = try? Data(contentsOf: resolved.file, options: .mappedIfSafe),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": resolved.contentType, "Cache-Control": "no-store"]
              ) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
