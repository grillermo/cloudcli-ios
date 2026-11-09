import DataSource
import Foundation

/// Pure helpers for the page bridge, kept free of WebKit so they can be tested.
public enum NativeBridgeSupport {
    /// Whether an origin is the app's own `cloudcli://app`.
    public static func isAppOrigin(scheme: String?, host: String?) -> Bool {
        scheme == AppScheme.scheme && host == AppScheme.host
    }

    public static func isAppPage(_ url: URL?) -> Bool {
        isAppOrigin(scheme: url?.scheme, host: url?.host())
    }

    public struct Ready: Equatable, Sendable {
        public let buildID: String?
    }

    /// A ready signal counts only from the main frame of the app origin.
    public static func parseReady(body: Any, isMainFrame: Bool, scheme: String?, host: String?) -> Ready? {
        guard isMainFrame, isAppOrigin(scheme: scheme, host: host),
              let dictionary = body as? [String: Any], dictionary["type"] as? String == "ready" else { return nil }
        return Ready(buildID: dictionary["buildId"] as? String)
    }

    /// The script that hands `text` to the composer. The text is a JSON string literal inside a
    /// one-element array, then indexed, so no character of it can end the literal. U+2028 and U+2029
    /// are escaped as well, for engines that treat them as line terminators.
    public static func insertScript(for text: String) -> String? {
        guard let data = try? JSONEncoder().encode([text]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.__nativeDictation ? window.__nativeDictation.insert(\(safe)[0]) : false"
    }

    /// A `cloudcli://session/<id>` link maps to one path segment. Anything else is ignored.
    public static func sessionTarget(path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty, !trimmed.contains("/"),
              trimmed.range(of: "^[A-Za-z0-9._~%-]+$", options: .regularExpression) != nil,
              let decoded = trimmed.removingPercentEncoding,
              !decoded.isEmpty, decoded != ".", decoded != ".." else { return nil }
        return URL(string: "cloudcli://app/session/\(trimmed)")
    }
}
