import Foundation

public enum AppSchemeResolver {
    public struct Resolved: Equatable, Sendable {
        public let file: URL
        public let contentType: String
    }

    private static let contentTypes = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "wasm": "application/wasm",
        "webmanifest": "application/manifest+json",
    ]

    public static func resolve(_ url: URL, root: URL) -> Resolved? {
        // Resolve symlinks on both sides so a link inside the build cannot point outside it,
        // and so a root reached through a link (/var -> /private/var) still matches.
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let index = base.appending(path: "index.html")
        let requested = String(url.path(percentEncoded: false).drop { $0 == "/" })
        let candidate = base.appending(path: requested).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        let isInside = candidate.path.hasPrefix(base.path + "/")
        let file = exists && !isDirectory.boolValue && isInside ? candidate : index
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return Resolved(
            file: file,
            contentType: contentTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        )
    }
}
