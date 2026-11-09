import Foundation

public struct MemaCredentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Normalises the base URL (whitespace, missing scheme, trailing slashes, a
    /// pasted `/v1`) and rejects anything that is not a plain http(s) origin
    /// or path: credentials, queries and fragments in the URL are refused so a
    /// secret can never travel inside it.
    public init?(urlText: String, token: String) {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/v1") { text.removeLast(3) }
        while text.hasSuffix("/") { text.removeLast() }

        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil,
              url.query() == nil, url.fragment() == nil
        else { return nil }
        self.init(baseURL: url, token: token)
    }

    public static func parsePasted(_ text: String) -> MemaCredentials? {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            values[key] = value
        }
        guard let url = values["VOICE_API_BASE_URL"], let token = values["VOICE_API_KEY"] else { return nil }
        return MemaCredentials(urlText: url, token: token)
    }

    public var description: String { "MemaCredentials(baseURL: \(baseURL.absoluteString), token: <redacted>)" }
    public var debugDescription: String { description }
}
