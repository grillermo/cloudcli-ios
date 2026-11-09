import Foundation

public struct BuildManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let size: Int

        public init(path: String, sha256: String, size: Int) {
            self.path = path
            self.sha256 = sha256
            self.size = size
        }
    }

    public let buildId: String
    public let files: [File]

    public init(buildId: String, files: [File]) {
        self.buildId = buildId
        self.files = files
    }

    public static func fetch(session: URLSession = .shared) async throws -> BuildManifest {
        var request = URLRequest(url: AppScheme.server.appending(path: "asset-manifest.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(BuildManifest.self, from: data)
    }
}
