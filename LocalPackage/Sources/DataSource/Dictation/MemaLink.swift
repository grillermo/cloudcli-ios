import Foundation

/// A `fonos://model?...` or `cloudcli://model?...` link that carries dictation credentials.
/// Parsing never saves anything: the app must ask the user first.
public struct MemaLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let credentials: MemaCredentials

    public init(name: String, credentials: MemaCredentials) {
        self.name = name
        self.credentials = credentials
    }

    /// The server host to show in the confirmation, never the key.
    public var serverHost: String { credentials.baseURL.host() ?? credentials.baseURL.absoluteString }

    public var description: String { "MemaLink(name: \(name), credentials: \(credentials))" }
    public var debugDescription: String { description }
}

extension MemaCredentials {
    public static let linkSchemes: Set<String> = ["fonos", "cloudcli"]
    public static let linkHost = "model"

    /// Returns nil for any other scheme or host, and for missing or invalid `base_url` / `api_key`.
    /// `name` and `model` are informational; a missing `name` falls back to the server host.
    public static func parse(link: URL) -> MemaLink? {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), linkSchemes.contains(scheme),
              components.host?.lowercased() == linkHost
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, values[item.name] == nil { values[item.name] = value }
        }
        guard let baseURL = values["base_url"], let key = values["api_key"],
              let credentials = MemaCredentials(urlText: baseURL, token: key)
        else { return nil }
        let name = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = credentials.baseURL.host() ?? "server"
        return MemaLink(name: name.isEmpty ? host : name, credentials: credentials)
    }
}
